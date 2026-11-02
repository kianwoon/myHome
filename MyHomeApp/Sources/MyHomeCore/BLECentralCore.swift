// baseline-guard:allow new BLE source split out of BLEManager (perf: off the main thread)
// The CoreBluetooth side of BLEManager. Runs on ONE dedicated serial queue:
// the delegate callbacks (hundreds of duplicate adverts per second while
// scanning) never touch the main thread. Every mutable CB field below is
// confined to `queue`; the few facts the main actor must read synchronously
// (live ids, diagnostics, last-advert times) sit behind `lock`.
//
// The main actor sees state only through coalesced `BLEFlush` batches, sent
// at most once per `BLECentralCore.publishInterval` and only while adverts
// are heard. Raw rssi churn is never published (a light's rssi is frozen at
// first sight, as before).

@preconcurrency import CoreBluetooth
import Foundation

/// One coalesced batch for the main actor. `lights`/`states`/`isBluetoothOn`
/// are nil when unchanged since the previous batch.
struct BLEFlush {
    var lights: [BLELight]?
    var states: [String: DeviceStore.BriturnState]?
    var isBluetoothOn: Bool?
}

final class BLECentralCore: NSObject, @unchecked Sendable {
    /// Upper bound on main-actor publishes from BLE (2 Hz).
    static let publishInterval: TimeInterval = 0.5
    static let queueLabel = "myhome.ble.central"
    private static let disconnectDelay: TimeInterval = 2.5
    /// A connect that has not reached notify-ready by then is abandoned and
    /// logged (e.g. the bulb's single link is held by the phone app).
    private static let connectTimeout: TimeInterval = 10
    private static let ffffServiceData = CBUUID(string: "0000FFFF-0000-1000-8000-00805F9B34FB")

    let queue = DispatchQueue(label: queueLabel, qos: .utility)
    /// Called on `queue` with each coalesced batch.
    var onFlush: ((BLEFlush) -> Void)?

    // MARK: queue-confined state
    private var central: CBCentralManager?
    private var peripherals: [String: CBPeripheral] = [:]   // id -> peripheral
    private var lights: [BLELight] = []
    private var states: [String: DeviceStore.BriturnState] = [:]
    private var isBluetoothOn = false
    /// Pre-filter advert accounting (every peripheral heard, accepted or not).
    private var advertUUIDsSeen: Set<UUID> = []
    private var advertUUIDsAccepted: Set<UUID> = []
    /// Last logged Tuya-style payload signature per peripheral (log again only on change).
    private var tuyaPayloadSeen: [UUID: String] = [:]
    // Identity is the PERIPHERAL UUID everywhere (ids, link state). Manufacturer
    // data is only ever used to decode state: the bytes once used as a "MAC"
    // were state plus a fixed product tail and collided across bulbs.
    /// Pending post-connect actions; the argument is nil on success or the
    /// failure reason (logged by the caller).
    private var connectRequests: [UUID: [(String?) -> Void]] = [:]
    private var writeChars: [UUID: CBCharacteristic] = [:]
    private var notifyReady: [UUID: Bool] = [:]
    private var seq: UInt8 = 0
    /// Devices commanded recently keep their connection briefly so a slider
    /// burst doesn't reconnect per step.
    private var disconnectTasks: [UUID: DispatchWorkItem] = [:]
    private var connectTimeouts: [UUID: DispatchWorkItem] = [:]
    private var lightsDirty = false
    private var statesDirty = false
    private var powerDirty = false
    private var flushScheduled = false

    // MARK: lock-protected (read synchronously from the main actor)
    private let lock = NSLock()
    private var sharedLiveIDs: Set<String> = []
    private var sharedDiagnostics = BLEDiagnostics()
    private var sharedLastAdvert: [String: Date] = [:]

    init(startCentral: Bool, summaryInterval: TimeInterval) {
        super.init()
        sharedDiagnostics.authorization = BLEAuthorization(CBCentralManager.authorization)
        guard startCentral else { return }
        queue.async { [self] in
            central = CBCentralManager(delegate: self, queue: queue)
            scheduleSummary(every: summaryInterval)
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func hasPeripheral(id: String) -> Bool { locked { sharedLiveIDs.contains(id) } }
    var diagnostics: BLEDiagnostics { locked { sharedDiagnostics } }
    /// Time the latest accepted advert (or notify frame) for `id` was heard this run.
    func lastAdvert(for id: String) -> Date? { locked { sharedLastAdvert[id] } }

    private func updateDiagnostics(_ change: (inout BLEDiagnostics) -> Void) {
        locked { change(&sharedDiagnostics) }
    }

    private func scheduleSummary(every interval: TimeInterval) {
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.logSummary()
            self?.scheduleSummary(every: interval)
        }
    }

    private func logSummary() {
        let d = diagnostics
        let total = advertUUIDsSeen.count, acc = advertUUIDsAccepted.count
        let lastSeen = d.lastDiscovery.map { ISO8601DateFormatter().string(from: $0) } ?? "never"
        AppLog.ble.notice("MyHome: BLE auth=\(d.authorization.rawValue, privacy: .public) state=\(d.state.rawValue, privacy: .public) scanning=\(d.isScanning ? 1 : 0, privacy: .public) live=\(d.liveCount, privacy: .public) lastSeen=\(lastSeen, privacy: .public) peripherals=\(total, privacy: .public) accepted=\(acc, privacy: .public) filtered=\(total - acc, privacy: .public)")
    }

    /// The one and only light identity: the CoreBluetooth peripheral UUID.
    static func lightID(for uuid: UUID) -> String { "ble-" + uuid.uuidString.lowercased() }

    // MARK: - Coalesced publishing

    /// Arms one flush per interval; adverts heard in between ride along.
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + Self.publishInterval) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            self.onFlush?(self.takeFlush())
        }
    }

    /// Builds the batch of changed fields and clears the dirty flags (queue only).
    func takeFlush() -> BLEFlush {
        let flush = BLEFlush(lights: lightsDirty ? lights : nil,
                             states: statesDirty ? states : nil,
                             isBluetoothOn: powerDirty ? isBluetoothOn : nil)
        lightsDirty = false
        statesDirty = false
        powerDirty = false
        return flush
    }

    // MARK: - Commands (enqueued from the main actor)

    /// LEDnetWF transport wrapper (version 0, single segment): every command
    /// to FF01 MUST be wrapped — raw bytes are ignored by this profile.
    /// [0x00 header][seq][0x80 0x00 frag][len BE][len+1][cmdId 10/11][payload]
    private func transport(_ command: [UInt8], expectsResponse: Bool = false) -> [UInt8] {
        seq = seq &+ 1
        let len = command.count
        return [0x00, seq, 0x80, 0x00,
                UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF),
                UInt8((len + 1) & 0xFF), expectsResponse ? 10 : 11] + command
    }

    func send(id: String, op: String, command: [UInt8]) {
        queue.async { [self] in sendOnQueue(id: id, op: op, command: command) }
    }

    private func label(_ peripheral: CBPeripheral) -> String {
        Self.lightID(for: peripheral.identifier)
    }

    private func sendOnQueue(id: String, op: String, command: [UInt8]) {
        let wrapped = transport(command)
        AppLog.ble.notice("MyHome: BLE cmd id=\(id, privacy: .public) op=\(op, privacy: .public) bytes=\(wrapped.count, privacy: .public) head=\(BLEWire.hexPrefix(command), privacy: .public)")
        guard let peripheral = peripherals[id], let central else {
            AppLog.ble.error("MyHome: BLE drop id=\(id, privacy: .public) op=\(op, privacy: .public) reason=no-live-peripheral")
            return
        }
        let key = peripheral.identifier
        if peripheral.state == .connected, notifyReady[key] == true, let writeChar = writeChars[key] {
            write(wrapped, op: op, to: peripheral, characteristic: writeChar)
            scheduleDisconnect(peripheral)
            return
        }
        connectAndThen(peripheral, central) { [weak self] failure in
            guard let self else { return }
            if let failure {
                AppLog.ble.error("MyHome: BLE drop id=\(id, privacy: .public) op=\(op, privacy: .public) reason=\(failure, privacy: .public)")
                return
            }
            guard peripheral.state == .connected, let writeChar = self.writeChars[key] else {
                AppLog.ble.error("MyHome: BLE drop id=\(id, privacy: .public) op=\(op, privacy: .public) reason=no-write-char-after-connect state=\(peripheral.state.rawValue, privacy: .public)")
                return
            }
            self.write(wrapped, op: op, to: peripheral, characteristic: writeChar)
        }
    }

    private func write(_ bytes: [UInt8], op: String, to peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        let props = BLEWire.describe(characteristic.properties)
        guard let type = BLEWire.writeType(for: characteristic.properties) else {
            AppLog.ble.error("MyHome: BLE drop id=\(self.label(peripheral), privacy: .public) op=\(op, privacy: .public) reason=char-not-writable char=\(characteristic.uuid.uuidString, privacy: .public) props=\(props, privacy: .public)")
            return
        }
        let typeName = type == .withResponse ? "withResponse" : "withoutResponse"
        AppLog.ble.notice("MyHome: BLE write id=\(self.label(peripheral), privacy: .public) op=\(op, privacy: .public) char=\(characteristic.uuid.uuidString, privacy: .public) type=\(typeName, privacy: .public) len=\(bytes.count, privacy: .public) props=\(props, privacy: .public)")
        peripheral.writeValue(Data(bytes), for: characteristic, type: type)
    }

    private func scheduleDisconnect(_ peripheral: CBPeripheral) {
        let key = peripheral.identifier
        disconnectTasks[key]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.connectRequests[key]?.isEmpty ?? true else { return }
            AppLog.ble.notice("MyHome: BLE idle disconnect id=\(self.label(peripheral), privacy: .public)")
            self.notifyReady[key] = false
            self.central?.cancelPeripheralConnection(peripheral)
        }
        disconnectTasks[key] = item
        queue.asyncAfter(deadline: .now() + Self.disconnectDelay, execute: item)
    }

    private func connectAndThen(_ peripheral: CBPeripheral, _ central: CBCentralManager,
                                _ after: @escaping (String?) -> Void) {
        let key = peripheral.identifier
        disconnectTasks[key]?.cancel()
        connectRequests[key, default: []].append(after)
        let pending = connectRequests[key]?.count ?? 0
        let id = label(peripheral)
        switch peripheral.state {
        case .connected where notifyReady[key] == true:
            finishConnect(peripheral, failure: nil)
        case .connected:
            // Connected but discovery never finished (or failed): redo it
            // rather than waiting for a notify-ready that will never come.
            AppLog.ble.notice("MyHome: BLE connected-not-ready id=\(id, privacy: .public) pending=\(pending, privacy: .public) -> rediscover")
            peripheral.delegate = self
            peripheral.discoverServices([BLEWire.service])
            armConnectTimeout(peripheral)
        case .connecting:
            AppLog.ble.notice("MyHome: BLE connect in progress id=\(id, privacy: .public) pending=\(pending, privacy: .public)")
        default:
            AppLog.ble.notice("MyHome: BLE connect requested id=\(id, privacy: .public) state=\(peripheral.state.rawValue, privacy: .public) pending=\(pending, privacy: .public)")
            central.connect(peripheral)
            armConnectTimeout(peripheral)
        }
    }

    private func armConnectTimeout(_ peripheral: CBPeripheral) {
        let key = peripheral.identifier
        connectTimeouts[key]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.notifyReady[key] != true else { return }
            AppLog.ble.error("MyHome: BLE connect timeout id=\(self.label(peripheral), privacy: .public) state=\(peripheral.state.rawValue, privacy: .public) (link held by another central, e.g. the phone app?)")
            self.central?.cancelPeripheralConnection(peripheral)
            self.finishConnect(peripheral, failure: "connect-timeout")
        }
        connectTimeouts[key] = item
        queue.asyncAfter(deadline: .now() + Self.connectTimeout, execute: item)
    }

    /// Drain every queued action for this peripheral exactly once.
    private func finishConnect(_ peripheral: CBPeripheral, failure: String?) {
        let key = peripheral.identifier
        connectTimeouts[key]?.cancel()
        connectTimeouts[key] = nil
        let callbacks = connectRequests[key] ?? []
        connectRequests[key] = nil
        callbacks.forEach { $0(failure) }
        // Re-arm the idle disconnect: the connect path cancelled it, and
        // without this the link stayed up forever (blocking the phone app).
        if failure == nil { scheduleDisconnect(peripheral) }
    }

    private func resetLink(_ peripheral: CBPeripheral) {
        let key = peripheral.identifier
        notifyReady[key] = false
        writeChars[key] = nil
        disconnectTasks[key]?.cancel()
        disconnectTasks[key] = nil
    }

    // MARK: - Advert decoding

    /// Records a decoded state; marks the batch dirty only on a real change.
    private func setState(_ id: String, _ state: DeviceStore.BriturnState) {
        guard states[id] != state else { return }
        states[id] = state
        statesDirty = true
    }

    /// Decode the ZengGe v7 manufacturer block. Verified live: with company
    /// id included (CoreBluetooth), POWER sits at byte 3 (0x23 on / 0x24 off).
    /// Only power is trusted here — colour offsets vary by firmware and painted
    /// garbage once already. r/g/b are decoded only when sub_mode is 0xF0
    /// (RGB active); otherwise the state is treated as non-colour.
    private func decodeState(_ id: String, mfr: Data, hasServiceData: Bool) {
        let b = [UInt8](mfr)
        guard b.count >= 12 else { return }
        let stateOffset = (hasServiceData && b[1] >= 7) ? 3 : 14
        guard b.count >= stateOffset + 11 else { return }
        let s = Array(b[stateOffset...])
        let on = s[0] == 0x23
        let subMode = s[2]
        let r = Int(s[4]), g = Int(s[5]), bl = Int(s[6])
        let isWhite = subMode == 0x0F
        let rgbActive = subMode == 0xF0 || (!isWhite && !(r == 0 && g == 0 && bl == 0))
        setState(id, DeviceStore.BriturnState(
            on: on,
            rawPower: Int(s[0]),
            mode: Int(s[1]),
            r: (rgbActive && !isWhite) ? r : 0,
            g: (rgbActive && !isWhite) ? g : 0,
            b: (rgbActive && !isWhite) ? bl : 0,
            w: rgbActive ? 0 : Int(s[3])
        ))
    }

    /// Registers a discovered light under its peripheral-UUID id and decodes
    /// state. Returns the id and whether it is new this run (queue only).
    func noteLight(uuid: UUID, name: String, rssi: Int, mfr: Data, hasServiceData: Bool) -> (id: String, isNew: Bool) {
        let id = Self.lightID(for: uuid)
        let isNew = !lights.contains { $0.id == id }
        if isNew {
            lights.append(BLELight(id: id, name: name, rssi: rssi))
            lights.sort { $0.name < $1.name }
            lightsDirty = true
        }
        if !mfr.isEmpty {
            decodeState(id, mfr: mfr, hasServiceData: hasServiceData)
        }
        return (id, isNew)
    }

    /// The accepted-advert path shared by the delegate and tests (queue only):
    /// registers the light, records liveness, and arms the coalesced flush.
    func ingestAccepted(uuid: UUID, peripheral: CBPeripheral?, name: String, rssi: Int,
                        mfr: Data, hasServiceData: Bool) {
        let (id, isNew) = noteLight(uuid: uuid, name: name, rssi: rssi,
                                    mfr: mfr, hasServiceData: hasServiceData)
        if let peripheral { peripherals[id] = peripheral }
        if isNew { AppLog.ble.notice("MyHome: BLE live peripheral id=\(id, privacy: .public) name=\(name, privacy: .public)") }
        let now = Date()
        let liveCount = peripherals.count
        locked {
            sharedLiveIDs.insert(id)
            sharedLastAdvert[id] = now
            sharedDiagnostics.liveCount = liveCount
            sharedDiagnostics.lastDiscovery = now
        }
        // Every heard advert arms (at most) one flush per interval: the batch
        // carries only changed fields, and the store uses it as its tick.
        scheduleFlush()
    }

    private func isZenggeMfrKey(_ key: Int) -> Bool {
        (0x5A00...0x5AFF).contains(key)
    }

    /// Feasibility log for Tuya-style adverts (public broadcast data): once per
    /// peripheral per run, again if the service/manufacturer bytes change.
    private func logTuyaAdvert(peripheral: CBPeripheral, name: String, advertisementData: [String: Any], rssi: Int) {
        let svcs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let mfrData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        var company: Int?
        if let d = mfrData, d.count >= 2 { company = Int(d[d.startIndex]) | (Int(d[d.startIndex + 1]) << 8) }
        guard BLEAdvert.isTuyaAdvert(name: name, mfrCompanyID: company, serviceUUIDs: svcs) else { return }
        let sd = (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]) ?? [:]
        let svcList = svcs.map(\.uuidString).joined(separator: ",")
        let sdList = sd.sorted { $0.key.uuidString < $1.key.uuidString }
            .map { "\($0.key.uuidString):\(BLEAdvert.hexString($0.value))" }.joined(separator: ",")
        let mfrHex = mfrData.map(BLEAdvert.hexString) ?? ""
        let signature = "\(svcList)|\(sdList)|\(mfrHex)"
        guard tuyaPayloadSeen[peripheral.identifier] != signature else { return }
        tuyaPayloadSeen[peripheral.identifier] = signature
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? false
        AppLog.ble.notice("MyHome: BLE tuya uuid=\(peripheral.identifier.uuidString.lowercased(), privacy: .public) name=\(name, privacy: .public) rssi=\(rssi, privacy: .public) svc=[\(svcList, privacy: .public)] svcdata=[\(sdList, privacy: .public)] mfr=\(mfrHex, privacy: .public) connectable=\(connectable, privacy: .public)")
    }
}

extension BLECentralCore: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let on = central.state == .poweredOn
        if on != isBluetoothOn {
            isBluetoothOn = on
            powerDirty = true
        }
        if on {
            // Duplicate reports ON: live state comes from repeated advertisements.
            central.scanForPeripherals(withServices: nil,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
        let scanning = on && central.isScanning
        updateDiagnostics { d in
            d.authorization = BLEAuthorization(CBCentralManager.authorization)
            d.state = BLEPowerState(central.state)
            d.isScanning = scanning
        }
        logSummary()
        scheduleFlush()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = localName ?? peripheral.name ?? ""
        let accepted = name.hasPrefix("IOTWF") || name.hasPrefix("LEDnetWF") || name.hasPrefix("IOTBT")
        // Pre-filter log: every peripheral once per run, whatever its name.
        if advertUUIDsSeen.insert(peripheral.identifier).inserted {
            AppLog.ble.notice("MyHome: BLE adv uuid=\(peripheral.identifier.uuidString.lowercased(), privacy: .public) name=\(localName ?? "", privacy: .public) periphName=\(peripheral.name ?? "", privacy: .public) rssi=\(RSSI.intValue, privacy: .public) mfr=\(BLEAdvert.mfrSummary(advertisementData), privacy: .public) accepted=\(accepted, privacy: .public)")
        }
        logTuyaAdvert(peripheral: peripheral, name: name, advertisementData: advertisementData, rssi: RSSI.intValue)
        guard accepted else { return }
        advertUUIDsAccepted.insert(peripheral.identifier)

        var mfr = Data()
        var hasServiceData = false
        if let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
           let sd = serviceData[Self.ffffServiceData], sd.count >= 16 {
            hasServiceData = true
        }
        if let all = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, all.count >= 2 {
            // raw AD blob includes the company id at the start
            mfr = all.count >= 29 ? all.subdata(in: 2..<all.count) : all
        }
        for (key, value) in (advertisementData[CBAdvertisementDataManufacturerDataKey] as? [AnyHashable: Data]) ?? [:] {
            if let keyNumber = key as? Int, isZenggeMfrKey(keyNumber) { mfr = value }
        }

        ingestAccepted(uuid: peripheral.identifier, peripheral: peripheral, name: name,
                       rssi: RSSI.intValue, mfr: mfr, hasServiceData: hasServiceData)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        AppLog.ble.error("MyHome: BLE didFailToConnect id=\(self.label(peripheral), privacy: .public) error=\(error?.localizedDescription ?? "none", privacy: .public)")
        resetLink(peripheral)
        finishConnect(peripheral, failure: "connect-failed")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let pending = connectRequests[peripheral.identifier]?.count ?? 0
        AppLog.ble.notice("MyHome: BLE didDisconnect id=\(self.label(peripheral), privacy: .public) pending=\(pending, privacy: .public) error=\(error?.localizedDescription ?? "none", privacy: .public)")
        resetLink(peripheral)
        if pending > 0 { finishConnect(peripheral, failure: "disconnected-before-ready") }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        AppLog.ble.notice("MyHome: BLE didConnect id=\(self.label(peripheral), privacy: .public)")
        peripheral.delegate = self
        peripheral.discoverServices([BLEWire.service])
    }
}

extension BLECentralCore: CBPeripheralDelegate {
    private func failDiscovery(_ peripheral: CBPeripheral, reason: String) {
        AppLog.ble.error("MyHome: BLE discovery failed id=\(self.label(peripheral), privacy: .public) reason=\(reason, privacy: .public)")
        central?.cancelPeripheralConnection(peripheral)
        resetLink(peripheral)
        finishConnect(peripheral, failure: reason)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        let uuids = services.map { $0.uuid.uuidString }.joined(separator: ",")
        AppLog.ble.notice("MyHome: BLE services id=\(self.label(peripheral), privacy: .public) uuids=[\(uuids, privacy: .public)] error=\(error?.localizedDescription ?? "none", privacy: .public)")
        if let error {
            failDiscovery(peripheral, reason: "services-error " + error.localizedDescription)
            return
        }
        guard !services.isEmpty else {
            failDiscovery(peripheral, reason: "no-FFFF-service")
            return
        }
        for service in services {
            peripheral.discoverCharacteristics([BLEWire.writeChar, BLEWire.notifyChar], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let key = peripheral.identifier
        let chars = service.characteristics ?? []
        let summary = chars.map { "\($0.uuid.uuidString)(\(BLEWire.describe($0.properties)))" }.joined(separator: ",")
        AppLog.ble.notice("MyHome: BLE characteristics id=\(self.label(peripheral), privacy: .public) service=\(service.uuid.uuidString, privacy: .public) chars=[\(summary, privacy: .public)] error=\(error?.localizedDescription ?? "none", privacy: .public)")
        if let error {
            failDiscovery(peripheral, reason: "characteristics-error " + error.localizedDescription)
            return
        }
        var notifyChar: CBCharacteristic?
        for characteristic in chars {
            if characteristic.uuid == BLEWire.writeChar { writeChars[key] = characteristic }
            if characteristic.uuid == BLEWire.notifyChar { notifyChar = characteristic }
        }
        guard writeChars[key] != nil else {
            failDiscovery(peripheral, reason: "no-FF01-write-char")
            return
        }
        if let notifyChar {
            peripheral.setNotifyValue(true, for: notifyChar)
        } else {
            // No FF02: nothing would ever report notify-ready, so the queue
            // used to strand. Writes do not need notifications.
            AppLog.ble.notice("MyHome: BLE no FF02 notify char id=\(self.label(peripheral), privacy: .public) -> ready without notify")
            notifyReady[key] = true
            finishConnect(peripheral, failure: nil)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == BLEWire.notifyChar else { return }
        let key = peripheral.identifier
        AppLog.ble.notice("MyHome: BLE notify id=\(self.label(peripheral), privacy: .public) enabled=\(characteristic.isNotifying ? 1 : 0, privacy: .public) error=\(error?.localizedDescription ?? "none", privacy: .public)")
        // A notify failure used to strand every queued command; the write
        // characteristic is usable regardless, so proceed when we have it.
        guard writeChars[key] != nil else {
            failDiscovery(peripheral, reason: "notify-without-write-char")
            return
        }
        notifyReady[key] = true
        finishConnect(peripheral, failure: nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            AppLog.ble.error("MyHome: BLE didWrite id=\(self.label(peripheral), privacy: .public) char=\(characteristic.uuid.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        } else {
            AppLog.ble.notice("MyHome: BLE didWrite id=\(self.label(peripheral), privacy: .public) char=\(characteristic.uuid.uuidString, privacy: .public) ok")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, data.count >= 8 else { return }
        // Re-based array: the old ArraySlice kept indices from 8, so the
        // relative subscripts below trapped. Offsets are relative to byte 8.
        let payload = Array([UInt8](data)[8...])
        // JSON-wrapped or binary payloads; either way the hex state frame
        // starts with 81 — decode power/mode/rgb the same as the WiFi path.
        guard payload.first == 0x81, payload.count >= 14 else { return }
        // Keyed by peripheral.identifier, like every other GATT callback.
        let id = label(peripheral)
        guard peripherals[id] != nil else { return }
        let now = Date()
        locked { sharedLastAdvert[id] = now }
        setState(id, DeviceStore.BriturnState(
            on: payload[2] == 0x23,
            rawPower: Int(payload[2]),
            mode: Int(payload[3]),
            r: Int(payload[6]),
            g: Int(payload[7]),
            b: Int(payload[8]),
            w: Int(payload[5])
        ))
        scheduleFlush()
    }
}

/// Pure advert helpers (nonisolated; used on the BLE queue and in tests).
enum BLEAdvert {
    /// Tuya BLE identifiers (feasibility logging only; no behaviour depends on them).
    static let tuyaNamePrefixes = ["TY", "TUYA_"]
    static let tuyaMfrCompanyID = 0x07D0
    static let tuyaServiceUUIDs: Set<CBUUID> = [CBUUID(string: "1910"), CBUUID(string: "A201"), CBUUID(string: "FD50")]

    /// True when an advert looks like a Tuya BLE device (name, company id or service UUID).
    static func isTuyaAdvert(name: String, mfrCompanyID: Int?, serviceUUIDs: [CBUUID]) -> Bool {
        if tuyaNamePrefixes.contains(where: { name.hasPrefix($0) }) { return true }
        if let id = mfrCompanyID, id == tuyaMfrCompanyID { return true }
        return serviceUUIDs.contains { tuyaServiceUUIDs.contains($0) }
    }

    static func hexString(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// "<companyId hex>/<payload length>" of the advertised manufacturer data, or "none".
    static func mfrSummary(_ adv: [String: Any]) -> String {
        let raw = adv[CBAdvertisementDataManufacturerDataKey]
        if let all = raw as? Data, all.count >= 2 {
            let company = Int(all[all.startIndex]) | (Int(all[all.startIndex + 1]) << 8)
            return String(format: "%04x/%d", company, all.count - 2)
        }
        if let dict = raw as? [AnyHashable: Data], let (k, v) = dict.first, let company = k as? Int {
            return String(format: "%04x/%d", company, v.count)
        }
        return "none"
    }
}
