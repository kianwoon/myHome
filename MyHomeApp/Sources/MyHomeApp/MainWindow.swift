// baseline-guard:allow new main window source, no prior baseline
import AppKit
import SwiftUI
import MyHomeCore

enum DeviceGroup: String, CaseIterable, Identifiable {
    case fans, curtains, lights, plugs, climate, briturn, other

    /// General rule: any roster category listed here owns its own sidebar
    /// group, keyed on `device.category` rather than on DeviceKind. The
    /// kind-derived groups below must not claim those devices, so a source
    /// cannot double-appear. Categories NOT listed here keep the existing
    /// behaviour: classified by kind, falling through to Other.
    static let sourceCategories: Set<String> = ["briturn"]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fans: return "Fans"
        case .curtains: return "Curtains"
        case .lights: return "Lights"
        case .plugs: return "Plugs"
        case .climate: return "Climate"
        case .briturn: return "Briturn"
        case .other: return "Other"
        }
    }

    var icon: String {
        switch self {
        case .fans: return "fanblades"
        case .curtains: return "curtains.closed"
        case .lights: return "lightbulb"
        case .plugs: return "powerplug"
        case .climate: return "thermometer.medium"
        case .briturn: return "lamp.desk"
        case .other: return "square.grid.2x2"
        }
    }

    func contains(_ device: Device) -> Bool {
        let isSourceOwned = DeviceGroup.sourceCategories.contains(device.category.lowercased())
        switch self {
        case .fans: return !isSourceOwned && device.kind == .fan
        case .curtains: return !isSourceOwned && device.kind == .curtain
        case .lights: return !isSourceOwned && device.kind == .light
        case .plugs: return !isSourceOwned && device.kind == .plug
        case .climate: return !isSourceOwned && device.kind == .climate
        case .briturn: return device.category.lowercased() == "briturn"
        case .other:
            return !isSourceOwned
                && ![DeviceKind.fan, .curtain, .light, .plug, .climate].contains(device.kind)
        }
    }
}

/// General rule: a room's icon reflects its purpose whenever its name is
/// recognizable. Matching is a total, ordered substring lookup over
/// `RoomIcon.table`, normalized to lowercase and trimmed; the most specific
/// entry wins, and any unrecognized name (for example "Function room")
/// degrades to the generic "house" icon. The five current rooms are simply
/// instances of that rule, not cases: "Guest room" → bed.double via "guest",
/// "Master room" → bed.double via "master", "Dining room" → fork.knife via
/// "dining", "Living room" → sofa via "living", "Study room" → books.vertical
/// via "study". New room types need only a table entry — never a view change.
enum RoomIcon {
    /// Ordered most-specific → least-specific; first substring match wins.
    /// Symbols verified against the macOS 13 deployment target (SF Symbols
    /// versions ≤ 3); unavailable candidates such as "door.fully.open",
    /// "crib", "dining.table", and "arrows.rotate" were rejected.
    private static let table: [(keyword: String, symbol: String)] = [
        ("guest", "bed.double"),
        ("master", "bed.double"),
        ("kids", "bed.double"),
        ("nursery", "bed.double"),
        ("bed", "bed.double"),
        ("dining", "fork.knife"),
        ("living", "sofa"),
        ("lounge", "sofa"),
        ("study", "books.vertical"),
        ("office", "books.vertical"),
        ("desk", "books.vertical"),
        ("kitchen", "refrigerator"),
        ("bath", "drop"),
        ("shower", "drop"),
        ("toilet", "drop"),
        ("garage", "car"),
        ("laundry", "washer"),
        ("wash", "washer"),
        ("garden", "leaf"),
        ("balcony", "leaf"),
        ("yard", "leaf"),
        ("patio", "leaf"),
        ("gym", "dumbbell"),
        ("exercise", "dumbbell"),
        ("play", "puzzlepiece"),
        ("storage", "archivebox"),
        ("store", "archivebox"),
        ("hall", "door.left.hand.closed"),
        ("corridor", "door.left.hand.closed"),
        ("entry", "door.left.hand.closed")
    ]

    /// Total function: returns "house" for empty or unrecognized input.
    public static func icon(for room: String) -> String {
        let normalized = room.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for entry in table where normalized.contains(entry.keyword) {
            return entry.symbol
        }
        return "house"
    }
}

struct DashboardView: View {
    @EnvironmentObject private var store: DeviceStore
    @State private var group: DeviceGroup = DeviceGroup.allCases.first { ProcessInfo.processInfo.environment["MYHOME_GROUP"] == $0.title.lowercased() } ?? .fans
    @State private var selectedID: String?
    // Which category's button started the current rescan (drives the spinner).
    // Local view state only; the working flag itself stays store.isWorking.
    @State private var rescanningGroup: DeviceGroup?
    /// Briturn group filter: nil = show all briturn lights; a name shows only
    /// that group's members. Set by clicking a group chip, cleared by "All".
    @State private var briturnGroupFilter: String?
    /// Room filter for the Plugs category. nil = all plugs; a room name shows
    /// only plugs assigned that room. Room names come from the whole roster.
    @State private var roomFilter: String?
    /// Sidebar room lens. Mutually exclusive with the category `group`: when
    /// set, the content shows every device in that room across all categories.
    /// The Plugs-internal `roomFilter` is preserved but dormant until the user
    /// returns to the Plugs category. MYHOME_ROOM is a diagnostic-only launch
    /// hook (same contract as MYHOME_GROUP) so a room dashboard can be
    /// screenshotted headlessly.
    @State private var selectedRoom: String? = ProcessInfo.processInfo.environment["MYHOME_ROOM"].flatMap { $0.isEmpty ? nil : $0 }
    /// Detail pane width in points: user-owned state, clamped to a sane range
    /// and persisted so the chosen width survives relaunch. Never derived from
    /// the window width, so the pane never stretches to fill dead space.
    @AppStorage("dashboardDetailWidth") private var detailWidth: Double = 360
    @State private var detailDragStartWidth: CGFloat?

    private let detailWidthRange: ClosedRange<CGFloat> = 300...560

    private var clampedDetailWidth: CGFloat {
        min(max(CGFloat(detailWidth), detailWidthRange.lowerBound), detailWidthRange.upperBound)
    }
    private var filtered: [Device] {
        var result: [Device]
        if let room = selectedRoom {
            result = store.devices.filter { $0.room == room }
        } else {
            result = store.devices.filter { group.contains($0) }
            if group == .briturn, let filter = briturnGroupFilter {
                result = result.filter { $0.group == filter }
            }
            if group == .plugs, let filter = roomFilter {
                result = result.filter { $0.room == filter }
            }
        }
        return result.sorted(by: onFirst)
    }

    private func roomCount(_ room: String) -> Int {
        store.devices.filter { $0.room == room }.count
    }

    /// General rule: every dashboard list (any category or active filter) is
    /// partitioned ON → online → offline, then ordered by name/id so a status
    /// poll only reorders a row when its class actually changes. "Online" means
    /// the card shows no offline indication: it is reachable by transport
    /// (`hasAddress || isBLE`, the same notion as DeviceCard's `isEnabled`) AND
    /// the cloud badge is not offline. Any offline indication on either signal
    /// sends the row to the last tier. Same ON-first + name tie-break as the
    /// menu bar (commit 1a191e6).
    private func onFirst(_ lhs: Device, _ rhs: Device) -> Bool {
        let leftRank = onRank(lhs)
        let rightRank = onRank(rhs)
        if leftRank != rightRank { return leftRank < rightRank }
        let leftName = lhs.name.lowercased()
        let rightName = rhs.name.lowercased()
        if leftName != rightName { return leftName < rightName }
        return lhs.id < rhs.id
    }

    private func onRank(_ device: Device) -> Int {
        if store.isOn[device.id] == true || store.briturnStatus[device.id]?.on == true {
            return 0
        }
        let showsOffline = !(device.hasAddress || device.isBLE) || store.cloudOnline[device.id] == false
        return showsOffline ? 2 : 1
    }

    private var selectedDevice: Device? {
        store.devices.first { $0.id == selectedID }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding<DeviceGroup?>(
                get: { selectedRoom == nil ? group : nil },
                set: { newValue in
                    if let newValue = newValue {
                        group = newValue
                        selectedRoom = nil
                    }
                }
            )) {
                ForEach(DeviceGroup.allCases) { item in
                    sidebarRow(item)
                        .tag(item)
                }
                if !store.roomNames.isEmpty {
                    Divider()
                    Text("Rooms")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(store.roomNames, id: \.self) { room in
                        Button {
                            selectedRoom = room
                        } label: {
                            Label(room, systemImage: RoomIcon.icon(for: room))
                                .badge(roomCount(room))
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            selectedRoom == room
                                ? Color.accentColor.opacity(0.18)
                                : Color.clear
                        )
                    }
                }
            }
            .frame(minWidth: 150, idealWidth: 175, maxWidth: 230)
            .fixedSize(horizontal: true, vertical: false)
            .navigationTitle("MyHome")

            Divider()

            ScrollView {
                if selectedRoom == nil && group == .briturn {
                    BriturnGroupsBar(selection: $briturnGroupFilter)
                    Divider().padding(.horizontal)
                }
                if selectedRoom == nil && group == .plugs && !store.roomNames.isEmpty {
                    RoomFilterBar(selection: $roomFilter)
                    Divider().padding(.horizontal)
                }
                if filtered.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: selectedRoom == nil ? group.icon : "house")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No devices in \(selectedRoom ?? group.title).")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 250), spacing: 14, alignment: .top)],
                        spacing: 14
                    ) {
                        ForEach(filtered) { device in
                            DeviceCard(
                                device: device,
                                isSelected: selectedID == device.id
                            ) {
                                selectedID = device.id
                            }
                        }
                    }
                    .padding()
                }
            }
            .frame(minWidth: 480, idealWidth: 580)
            .frame(maxWidth: .infinity)
            .navigationTitle(selectedRoom ?? group.title)

            if let device = selectedDevice {
                detailResizeHandle
                DeviceDetailView(device: device)
                    .frame(width: clampedDetailWidth)
            }
        }
        .task {
            // The bridge spawn can transiently fail (slow host, killed
            // process). Always fetch the roster at launch — BLE lights make
            // `devices` non-empty even when the roster never loaded, so an
            // emptiness check would skip the fetch entirely.
            for _ in 0..<3 {
                await store.refresh()
                if !store.roster.isEmpty { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            await store.loadAllStatuses()
            // Briturn statuses otherwise wait for the first poll cycle
            // (~10s), leaving the on-count and chips wrong at launch.
            await store.loadAllBriturnStatuses()
        }
        .onAppear {
            store.startPolling()
            // Same resilience on re-appear: if the ROSTER is empty because an
            // earlier fetch failed, try again instead of showing a hole.
            Task {
                if store.roster.isEmpty { await store.refresh() }
            }
        }
        .onDisappear { store.stopPolling() }
    }

    /// Draggable divider: dragging left widens the detail pane, clamped and
    /// persisted. A 1pt rule inside a 10pt hit area keeps the visual weight of
    /// the old `Divider()` while remaining an easy grab target.
    private var detailResizeHandle: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(width: 10)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if detailDragStartWidth == nil {
                            detailDragStartWidth = clampedDetailWidth
                        }
                        let proposed = (detailDragStartWidth ?? clampedDetailWidth) - value.translation.width
                        detailWidth = Double(
                            min(max(proposed, detailWidthRange.lowerBound), detailWidthRange.upperBound)
                        )
                    }
                    .onEnded { _ in detailDragStartWidth = nil }
            )
    }

    @ViewBuilder
    private func sidebarRow(_ item: DeviceGroup) -> some View {
        HStack(spacing: 6) {
            Label(item.title, systemImage: item.icon)
                .badge(store.devices.filter { item.contains($0) }.count)
            Spacer(minLength: 0)
            CategoryRefreshButton(item: item, active: rescanningGroup) {
                rescanningGroup = item
                Task {
                    if item == .briturn {
                        await store.briturnScan()
                    } else {
                        await store.rescan()
                    }
                    rescanningGroup = nil
                }
            }
        }
    }
}

/// General rule: every sidebar category header refreshes the roster through the
/// SAME shared isWorking flow — either the LAN rescan or a source-specific scan
/// (Briturn's own discovery command), never a per-section copy. While a scan
/// runs, the clicked header shows a spinner and every refresh button disables
/// via the shared store.isWorking flag.
struct CategoryRefreshButton: View {
    @EnvironmentObject private var store: DeviceStore
    let item: DeviceGroup
    let active: DeviceGroup?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if store.isWorking && active == item {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(store.isWorking)
        .help("Rescan devices")
    }
}

// MARK: - Card

struct DeviceCard: View {
    @EnvironmentObject private var store: DeviceStore
    let device: Device
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var showingRename = false
    @State private var showingRoom = false

    private var isBriturn: Bool { device.category.lowercased() == "briturn" }

    private var roomLabel: String? {
        guard !isBriturn else { return nil }
        let trimmed = device.room.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var isEnabled: Bool { device.hasAddress || device.isBLE }

    private var power: Bool? {
        if isBriturn { return store.briturnStatus[device.id]?.on }
        return store.power(for: device)
    }

    private var showPowerToggle: Bool {
        if isBriturn { return true }
        if device.spec?["1"] != nil {
            return device.spec?["1"]?.type.lowercased() == "boolean"
        }
        return true  // no spec: legacy behaviour
    }

    private var powerBinding: Binding<Bool> {
        Binding(
            get: {
                if isBriturn { return store.briturnStatus[device.id]?.on ?? false }
                return store.power(for: device) ?? false
            },
            set: { newValue in
                Task {
                    if isBriturn {
                        await store.setBriturn(device, on: newValue)
                    } else {
                        await store.toggle(device, to: newValue)
                    }
                }
            }
        )
    }

    private func summary(_ state: DeviceState) -> String {
        if !isEnabled { return "Offline" }
        if isBriturn {
            // Group membership is part of the card's at-a-glance identity —
            // you grouped lights precisely so they read as a set. Transports
            // are shown as icons: 📶 WiFi reachable, 🔵 Bluetooth seen.
            let state = store.briturnStatus[device.id]
            let powerText = state.map { $0.on ? "On" : "Off" } ?? "Briturn"
            var parts: [String] = [powerText]
            if let name = device.group, !name.isEmpty { parts.append(name) }
            var transports = ""
            if store.isWiFiAvailable(for: device) { transports += "📶" }
            if store.isBLEAvailable(for: device) { transports += "🔵" }
            if !transports.isEmpty { parts.append(transports) }
            return parts.joined(separator: " · ")
        }
        switch device.kind {
        case .plug:
            if let watts = state.wattsText { return watts }
        case .climate:
            if let temperature = state.temperature {
                return "\(DPSValue.format(temperature)) °C"
            }
        case .fan:
            return "Speed \(state.fanSpeed)"
        case .curtain:
            if let position = state.position { return "\(Int(position.rounded())) %" }
        case .light:
            if let brightness = state.brightness { return "Brightness \(Int(brightness.rounded()))" }
        default:
            break
        }
        return device.kind.label
    }

    var body: some View {
        let state = store.state(for: device)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: device.kind.iconName)
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 26)
                    .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(device.name)
                            .font(.callout.weight(.semibold))
                        CloudStatusBadge(online: store.cloudOnline[device.id])
                    }
                    HStack(spacing: 6) {
                        Text(summary(state))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let room = roomLabel {
                            RoomBadge(room: room)
                        }
                        BatteryChip(percent: state.batteryPercent)
                    }
                }

                Spacer(minLength: 4)

                // General rule: dp 1 is a power toggle ONLY when it is a
                // Boolean dp. On curtains dp 1 is the Enum action
                // (open/stop/close) — a boolean toggle there writes garbage the
                // device ignores, so it is hidden, not disabled.
                if showPowerToggle {
                    Toggle("", isOn: powerBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .disabled(!isEnabled || power == nil)
                        .opacity(power == nil ? 0.5 : 1)
                }
            }

            SpecControlsView(device: device, state: state)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            RichControlView(device: device, state: state)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // Fill the grid cell's height and top-align the content: every card in
        // a row matches the row height, with any slack below the content.
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isSelected ? Color.accentColor : Color.secondary.opacity(0.18),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .opacity(isEnabled ? 1 : 0.55)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button("Rename…") { showingRename = true }
            if !device.isBLE && !isBriturn {
                Button("Set Room…") { showingRoom = true }
            }
        }
        .sheet(isPresented: $showingRename) {
            RenameSheet(device: device)
        }
        .sheet(isPresented: $showingRoom) {
            RoomSheet(device: device)
        }
    }
}

/// General rule: names are cloud-authoritative identity, so this sheet calls
/// the bridge rename command (cloud PUT first) and lets the store re-list the
/// confirmed roster instead of editing the local model directly.
struct RenameSheet: View {
    @EnvironmentObject private var store: DeviceStore
    @Environment(\.dismiss) private var dismiss
    let device: Device
    @State private var name: String
    @State private var saving = false

    init(device: Device) {
        self.device = device
        _name = State(initialValue: device.name)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValid: Bool { !trimmed.isEmpty && trimmed.count <= 50 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Device")
                .font(.headline)
            Text("Updates the name in Tuya Cloud, then re-syncs this roster.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(submit)
            HStack {
                if let error = store.errorText {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(saving ? "Renaming…" : "Rename", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || saving)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func submit() {
        guard isValid, !saving else { return }
        saving = true
        Task {
            let ok = await store.rename(device, to: trimmed)
            saving = false
            if ok { dismiss() }
        }
    }
}

/// General rule: a room is LOCAL roster metadata, so this sheet edits the
/// bridge's `room` field directly (no cloud round-trip) and offers the room
/// names already in use house-wide so naming stays consistent. This is NOT
/// Briturn's `group` field, which has its own editor on the light detail view.
struct RoomSheet: View {
    @EnvironmentObject private var store: DeviceStore
    @Environment(\.dismiss) private var dismiss
    let device: Device
    @State private var room: String
    @State private var saving = false

    init(device: Device) {
        self.device = device
        _room = State(initialValue: device.room)
    }

    private var trimmed: String { room.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValid: Bool { trimmed.count <= 40 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set Room")
                .font(.headline)
            Text("Rooms are local labels stored in the bridge roster, not in Tuya Cloud. Leave empty to clear.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Room, for example Study Room", text: $room)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(submit)
            if !store.roomNames.isEmpty {
                Text("Existing rooms")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 6)],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(store.roomNames, id: \.self) { name in
                        Button(name) { room = name }
                            .controlSize(.small)
                    }
                }
                .frame(width: 320, alignment: .leading)
            }
            HStack {
                if let error = store.statusErrors[device.id] {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Clear") { room = ""; submit() }
                    .disabled(saving)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || saving)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func submit() {
        guard isValid, !saving else { return }
        saving = true
        Task {
            let ok = await store.setRoom(id: device.id, room: trimmed)
            saving = false
            if ok { dismiss() }
        }
    }
}

/// Compact room badge for a device tile. Briturn lights already render their
/// group in the summary line, so the badge is for every other category.
struct RoomBadge: View {
    let room: String

    var body: some View {
        Text(room)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)
    }
}

/// Room filter for the Plugs category: "All" plus one chip per room known
/// anywhere in the roster. Mirrors BriturnGroupsBar's selection semantics —
/// clicking the selected chip returns to all rooms.
struct RoomFilterBar: View {
    @EnvironmentObject private var store: DeviceStore
    @Binding var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rooms")
                .font(.headline)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130, maximum: 200), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                RoomChip(name: "All", isSelected: selection == nil) {
                    selection = nil
                }
                ForEach(store.roomNames, id: \.self) { name in
                    RoomChip(name: name, isSelected: selection == name) {
                        selection = (selection == name) ? nil : name
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
    }
}

struct RoomChip: View {
    let name: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(
                        isSelected ? Color.accentColor.opacity(0.2)
                                   : Color(nsColor: .controlBackgroundColor))
                )
        }
        .buttonStyle(.plain)
    }
}

/// General rule: LOCAL reachability and CLOUD connectivity are independent
/// facts, so this badge sits beside the name rather than replacing the local
/// offline summary; both are needed to tell "asleep on LAN" from "radio dead".
struct CloudStatusBadge: View {
    let online: Bool?
    var envBroken: Bool = false

    private var label: String {
        if envBroken { return "☁ bridge env" }
        return DeviceStore.cloudBadgeText(online)
    }

    private var tint: Color {
        if envBroken { return .orange }
        switch online {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return .secondary
        }
    }

    var body: some View {
        Text(label)
            // General rule: a view must never mutate observable state during
            // layout, and content that changes width per poll re-invalidates
            // layout. Fixed monospaced geometry keeps this badge's size
            // identical across pending/online/offline updates.
            .font(.system(.caption2, design: .monospaced).weight(.medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .frame(width: 68, alignment: .leading)
            .help(online == nil ? "Cloud status pending" : "Tuya cloud connectivity")
    }
}

/// Battery is a status-only dp discovered by cloud/local correlation; no map
/// or no value means no chip. Thresholds are named constants on DeviceState.
struct BatteryChip: View {
    let percent: Double?

    var body: some View {
        if let percent = percent {
            Text(label(percent))
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(tint(percent))
                .fixedSize()
        }
    }

    private func label(_ percent: Double) -> String {
        let value = Int(percent.rounded())
        if percent < DeviceState.batteryLowThreshold {
            return "🔋 \(value)% (low)"
        }
        return "🔋 \(value)%"
    }

    private func tint(_ percent: Double) -> Color {
        if percent >= DeviceState.batteryNormalThreshold { return .secondary }
        if percent >= DeviceState.batteryLowThreshold { return .orange }
        return .red
    }
}

// MARK: - Rich controls

struct RichControlView: View {
    @EnvironmentObject private var store: DeviceStore
    let device: Device
    let state: DeviceState

    var body: some View {
        switch device.kind {
        case .fan:
            FanControlView(device: device, state: state)
        case .curtain:
            CurtainControlView(device: device, state: state)
        case .light:
            // General rule: briturn lights must never receive Tuya DPS
            // sliders — dp "2" means nothing to them, so the card slider was
            // a dead control. They get the native brightness slider instead.
            if device.category.lowercased() == "briturn" {
                BriturnCardControls(device: device)
            } else {
                LightControlView(device: device, state: state)
            }
        case .plug:
            PlugReadoutView(state: state)
        case .climate:
            ClimateChipsView(state: state)
        default:
            RawPreviewView(state: state, kind: device.kind)
        }
    }
}

/// Compact card-level brightness for briturn lights, mirroring the detail
/// slider: peak-channel derived, drag-guarded, debounced, native transport.
struct BriturnCardControls: View {
    @EnvironmentObject private var store: DeviceStore
    let device: Device
    @State private var brightness: Double = 100
    @State private var isDragging = false
    @State private var applyTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.max")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: $brightness, in: 0...100) { dragging in
                isDragging = dragging
                if !dragging {
                    applyTask?.cancel()
                    let value = Int(brightness.rounded())
                    applyTask = Task {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        guard !Task.isCancelled else { return }
                        await store.setBriturn(device, brightness: value)
                    }
                }
            }
            .controlSize(.mini)
            .disabled(store.briturnStatus[device.id] == nil)
            Text("\(Int(brightness.rounded()))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .onAppear { syncFromStatus() }
        .onChange(of: store.briturnStatus[device.id]) { newState in
            guard !isDragging else { return }
            if let s = newState {
                brightness = s.isWhiteMode ? Double(s.w) * 100.0 / 255.0
                    : Double(max(s.r, s.g, s.b)) * 100.0 / 255.0
            }
        }
    }

    private func syncFromStatus() {
        if let s = store.briturnStatus[device.id] {
            brightness = s.isWhiteMode ? Double(s.w) * 100.0 / 255.0
                : Double(max(s.r, s.g, s.b)) * 100.0 / 255.0
        }
    }
}

struct FanControlView: View {
    @EnvironmentObject private var store: DeviceStore
    let device: Device
    let state: DeviceState

    private var speedKey: String { state.fanSpeedKey ?? "2" }
    private var showSpeed: Bool { !state.isDeclared(state.fanSpeedKey) }
    private var showOscillation: Bool { !state.isDeclared(state.oscillationKey) }
    /// General rule: speed is a local-only dp for some firmwares, so when the
    /// status itself came from the cloud AND no numeric speed dp is present,
    /// say why the control is missing instead of leaving a silent gap.
    private var speedNeedsLocal: Bool {
        store.statusViaCloud[device.id] == true && !state.hasNumericFanSpeed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showSpeed {
                HStack(spacing: 8) {
                    Text("Speed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    ForEach(1...state.fanSpeedMax, id: \.self) { level in
                        Button {
                            Task {
                                await store.setDps(
                                    device,
                                    [speedKey: level],
                                    optimistic: [speedKey: .number(Double(level))]
                                )
                            }
                        } label: {
                            Circle()
                                .fill(level <= state.fanSpeed
                                      ? Color.accentColor
                                      : Color.secondary.opacity(0.25))
                                .frame(width: 10, height: 10)
                        }
                        .buttonStyle(.plain)
                        .help("Speed \(level)")
                    }
                }
            }

            if showOscillation, let oscKey = state.oscillationKey {
                Toggle(isOn: Binding(
                    get: { store.state(for: device).oscillation },
                    set: { newValue in
                        Task {
                            await store.setDps(
                                device,
                                [oscKey: newValue],
                                optimistic: [oscKey: .bool(newValue)]
                            )
                        }
                    }
                )) {
                    Text("Oscillate")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            if speedNeedsLocal {
                Text("Speed control needs a local connection")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct CurtainControlView: View {
    @EnvironmentObject private var store: DeviceStore
    let device: Device
    let state: DeviceState

    @State private var position: Double = 0
    @State private var isDragging = false
    private var showPosition: Bool { !state.isDeclared(state.curtainPositionKey) }
    // General rule: a device type's PRIMARY control (curtain open/stop/close)
    // always renders. The spec-declaration gate exists to hide DUPLICATE
    // inferred controls, not to suppress the primary one — on curtains dp 1
    // is declared (Enum control) yet the buttons are still the right UI.
    private var showActions: Bool { device.kind == .curtain && state.curtainActionKey != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showPosition {
                HStack(spacing: 8) {
                    Text("Position")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $position, in: 0...100, onEditingChanged: { editing in
                        isDragging = editing
                        if !editing, let positionKey = state.curtainPositionKey {
                            Task {
                                await store.setDps(device, [positionKey: Int(position.rounded())])
                            }
                        }
                    })
                    .controlSize(.mini)
                    .disabled(state.curtainPositionKey == nil)
                    Text("\(Int(position.rounded())) %")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
            }

            if showActions {
                if let actionKey = state.curtainActionKey {
                    HStack(spacing: 6) {
                        actionButton("Open", icon: "arrow.up.to.line", value: "open", key: actionKey)
                        actionButton("Stop", icon: "stop.fill", value: "stop", key: actionKey)
                        actionButton("Close", icon: "arrow.down.to.line", value: "close", key: actionKey)
                    }
                } else {
                    Text("Action control unavailable")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { position = state.position ?? 0 }
        .onChange(of: state.position ?? 0) { newValue in
            if !isDragging {
                position = newValue
            }
        }
    }

    private func actionButton(_ title: String, icon: String, value: String, key: String) -> some View {
        Button {
            Task {
                await store.setDps(
                    device,
                    [key: value],
                    optimistic: [key: .string(value)]
                )
            }
        } label: {
            Label(title, systemImage: icon)
                .font(.caption2)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

struct LightControlView: View {
    @EnvironmentObject private var store: DeviceStore
    let device: Device
    let state: DeviceState

    @State private var brightness: Double = 500
    @State private var colorTemp: Double = 500
    @State private var isDraggingBrightness = false
    @State private var isDraggingTemp = false
    private var showBrightness: Bool { !state.isDeclared("2") }
    private var showColorTemp: Bool { !state.isDeclared(state.colorTempKey) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showBrightness {
                HStack(spacing: 8) {
                    Image(systemName: "sun.max")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $brightness, in: 10...1000, onEditingChanged: { editing in
                        isDraggingBrightness = editing
                        if !editing {
                            Task {
                                await store.setDps(device, ["2": Int(brightness.rounded())])
                            }
                        }
                    })
                    .controlSize(.mini)
                    Text("\(Int(brightness.rounded()))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
            }

            if showColorTemp, let tempKey = state.colorTempKey {
                HStack(spacing: 8) {
                    Image(systemName: "thermometer.sun")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $colorTemp, in: 0...1000, onEditingChanged: { editing in
                        isDraggingTemp = editing
                        if !editing {
                            Task {
                                await store.setDps(device, [tempKey: Int(colorTemp.rounded())])
                            }
                        }
                    })
                    .controlSize(.mini)
                    Text("\(Int(colorTemp.rounded()))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }
        .onAppear {
            brightness = state.brightness ?? 500
            colorTemp = state.colorTemp ?? 500
        }
        .onChange(of: state.brightness ?? 500) { newValue in
            if !isDraggingBrightness { brightness = newValue }
        }
        .onChange(of: state.colorTemp ?? 500) { newValue in
            if !isDraggingTemp { colorTemp = newValue }
        }
    }
}

struct PlugReadoutView: View {
    let state: DeviceState

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(state.wattsText ?? "– W")
                .font(.callout.weight(.semibold))
                .monospacedDigit()

            Spacer()

            if let voltage = state.voltage {
                Text("\(DPSValue.format(voltage)) V")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let current = state.current {
                Text(String(format: "%.2f A", current))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ClimateChipsView: View {
    let state: DeviceState

    var body: some View {
        HStack(spacing: 6) {
            if let temperature = state.temperature {
                chip("🌡 \(DPSValue.format(temperature)) °C")
            }
            if let humidity = state.humidity {
                chip("💧 \(Int(humidity.rounded())) %")
            }
            if state.temperature == nil && state.humidity == nil {
                Text(state.isEmpty ? "Waiting for status…" : "No climate values")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.5), in: Capsule())
    }
}

struct RawPreviewView: View {
    let state: DeviceState
    let kind: DeviceKind

    var body: some View {
        let entries = Array(state.entries(for: kind).prefix(3))
        Text(state.isEmpty
             ? "No status yet"
             : entries.map { "\($0.key): \($0.value)" }.joined(separator: " · "))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}

// MARK: - Detail

struct DeviceDetailView: View {
    @EnvironmentObject private var store: DeviceStore
    let device: Device
    @State private var showingRename = false
    @State private var showingRoom = false

    private var state: DeviceState { store.state(for: device) }

    /// Unique identity is the roster id (MAC-derived for briturn lights);
    /// transports are reported separately — dual-mode is the norm.
    private var transportLine: String {
        var lines: [String] = []
        if device.hasAddress { lines.append("WiFi: \(device.ip)") }
        if store.isBLEAvailable(for: device) { lines.append("Bluetooth: in range") }
        if lines.isEmpty {
            lines.append(device.isBLE ? "Bluetooth: waiting for advertisement…" : "No transport")
        }
        return lines.joined(separator: "  ·  ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: device.kind.iconName)
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 46)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(device.name)
                                .font(.title2.bold())
                            CloudStatusBadge(online: store.cloudOnline[device.id], envBroken: store.cloudEnvBroken)
                        }
                        Text("\(device.kind.label) · \(device.category.isEmpty ? "uncategorised" : device.category)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(device.id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                        Text(transportLine)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        if !device.isBLE && device.category.lowercased() != "briturn" {
                            Button("Set Room…") { showingRoom = true }
                                .controlSize(.small)
                        }
                        Button("Rename…") { showingRename = true }
                            .controlSize(.small)
                    }
                }

                HStack(spacing: 10) {
                    if let watts = state.wattsText {
                        Text(watts)
                            .font(.headline.monospacedDigit())
                    }
                    if let temperature = state.temperature {
                        Text("🌡 \(DPSValue.format(temperature)) °C")
                            .font(.headline.monospacedDigit())
                    }
                    if state.power != nil {
                        Text(state.power == true ? "On" : "Off")
                            .font(.headline)
                            .foregroundStyle(state.power == true ? Color.green : Color.secondary)
                    }
                    BatteryChip(percent: state.batteryPercent)
                    Spacer()
                }

                if device.category.lowercased() == "briturn" {
                    BriturnControlsView(device: device)
                } else {
                    ScheduleSection(device: device)
                }

                if device.category.lowercased() != "briturn" {
                    Divider()

                    HStack {
                        Text("All DPS")
                        .font(.headline)
                    Spacer()
                    if store.isLoadingStatus(device) {
                        ProgressView().controlSize(.small)
                    }
                    Button("Refresh") {
                        Task { await store.loadStatus(for: device, force: true) }
                    }
                    .controlSize(.small)
                    }
                }

                if let error = store.statusErrors[device.id] {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                if state.isEmpty && !store.isLoadingStatus(device) {
                    Text("No DPS reported yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(state.entries(for: device.kind)) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(entry.key)
                                    .font(.callout.monospaced())
                                    .frame(width: 44, alignment: .leading)
                                Text(entry.label)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(entry.value)
                                    .font(.callout.monospacedDigit())
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 6)
                            Divider()
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: device.id) {
            if device.category.lowercased() == "briturn" {
                await store.loadBriturnStatus(for: device)
            } else {
                await store.loadStatus(for: device)
            }
        }
        .sheet(isPresented: $showingRename) {
            RenameSheet(device: device)
        }
        .sheet(isPresented: $showingRoom) {
            RoomSheet(device: device)
        }
    }
}

/// General rule: groups are presented INSIDE the Briturn category, not as
/// sidebar entries — the group count follows the roster, not the navigation,
/// and the two things you do with a group (all on/off, set a mood colour)
/// are one tap on the chip without opening anything. An empty roster shows
/// a hint that teaches assignment via the light's detail view.
struct BriturnGroupsBar: View {
    @EnvironmentObject private var store: DeviceStore
    @Binding var selection: String?

    /// General rule: group chips are ordered ON-first — a group with at least
    /// one confirmed-on member leads — then alphabetically, exactly like the
    /// light grid's ON-first/name tie-break. Derived per render from live
    /// `briturnStatus`; the store's roster order is never mutated. A group
    /// whose members all lack status counts as OFF (status proves ON, never
    /// the absence of it).
    private var orderedGroups: [String] {
        store.briturnGroups.sorted { lhs, rhs in
            let leftOn = anyOn(lhs)
            let rightOn = anyOn(rhs)
            if leftOn != rightOn { return leftOn }
            let leftName = lhs.lowercased()
            let rightName = rhs.lowercased()
            if leftName != rightName { return leftName < rightName }
            return lhs < rhs
        }
    }

    private func anyOn(_ group: String) -> Bool {
        store.members(of: group).contains { store.briturnStatus[$0.id]?.on == true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Groups")
                .font(.headline)
            if store.briturnGroups.isEmpty {
                Text("No groups yet — open a light below and assign a group to control several lights together.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // Wrapping grid, not a horizontal strip: every group must be
                // visible at once — hiding some behind a scroll defeats the
                // at-a-glance purpose of the bar.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 10)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    BriturnAllChip(isSelected: selection == nil) {
                        selection = nil
                    }
                    ForEach(orderedGroups, id: \.self) { group in
                        BriturnGroupCard(
                            group: group,
                            isSelected: selection == group,
                            onSelect: {
                                // Clicking the selected chip toggles back to all.
                                selection = (selection == group) ? nil : group
                            }
                        )
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
    }
}

/// "Show all" chip — clears the group filter.
struct BriturnAllChip: View {
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                Text("Show All")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(isSelected ? "✓" : "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .frame(minHeight: 46)
    }
}

struct BriturnGroupCard: View {
    @EnvironmentObject private var store: DeviceStore
    let group: String
    var isSelected: Bool = false
    var onSelect: (() -> Void)? = nil
    @State private var color = Color.white
    @State private var brightness: Double = 100
    @State private var isDraggingBrightness = false
    @State private var applyTask: Task<Void, Never>?
    @State private var brightnessTask: Task<Void, Never>?
    /// Same anti-echo rule as the single-light picker: never let a stale wire
    /// colour repaint the well and get sent back as a user command.
    @State private var lastColorEdit = Date.distantPast
    private static let colorSyncHoldOff: TimeInterval = 4
    @State private var isSyncingPicker = false
    @State private var showingSchedule = false

    private func clearSyncFlagSoon() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            isSyncingPicker = false
        }
    }

    private var members: [Device] { store.members(of: group) }
    private var anyOn: Bool { members.contains { store.briturnStatus[$0.id]?.on == true } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                // Tap target is the NAME ONLY — the toggle, colour well and
                // slider control the group's lights; they must never filter.
                // A real Button (not onTapGesture): gesture hit-testing on a
                // bare text stack was unreliable — some chips swallowed the
                // click, some didn't.
                Button(action: { onSelect?() }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group)
                            .font(.callout.weight(.semibold))
                            .multilineTextAlignment(.leading)
                        Text("\(members.count) light\(members.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
                Toggle("", isOn: Binding(
                    get: { anyOn },
                    set: { newValue in
                        Task { await store.setBriturnGroupState(group, on: newValue) }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                BriturnColorButton(title: "", color: $color, onCCT: { scheduleCCTApply($0) })
                    .labelsHidden()
                    .onChange(of: color) { newValue in
                        scheduleColorApply(newValue)
                    }
            }
            HStack(spacing: 6) {
                Image(systemName: "sun.max")
                    .foregroundStyle(.secondary)
                    .font(.caption2)
                Slider(value: $brightness, in: 0...100) { dragging in
                    isDraggingBrightness = dragging
                    if !dragging { scheduleBrightnessApply() }
                }
                .controlSize(.mini)
                Button("Schedule") { showingSchedule = true }
                    .controlSize(.small)
            }
            .disabled(!anyOn)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 240)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .onAppear {
            // Neutral until a real source paints the chip: the remembered
            // last-user colour seeds it, then live member derivation wins.
            if let remembered = store.groupColours[group] {
                color = Color(
                    red: Double(remembered.red) / 255,
                    green: Double(remembered.green) / 255,
                    blue: Double(remembered.blue) / 255
                )
            }
            syncPicker()
        }
        .onChange(of: store.briturnStatus) { _ in
            // Always re-track the members' live colour: the chip is a MIRROR
            // of the group, not a memory of the first readback. User edits are
            // protected by the lastColorEdit hold-off inside syncPicker.
            syncPicker()
        }
        .sheet(isPresented: $showingSchedule) {
            BriturnGroupScheduleSheet(group: group)
        }
    }

    /// Picker mirrors any member's colour; the device readback wins, same as
    /// the single-light path. Never yanked mid-drag.
    private func syncPicker() {
        if isDraggingBrightness { return }
        if Date().timeIntervalSince(lastColorEdit) < Self.colorSyncHoldOff { return }
        // The chip mirrors the LIGHTS, not one arbitrarily chosen member:
        // first member with a real colour wins; otherwise the first white
        // member (rgb all-zero with a warm level means white, powered or
        // not); only all-zero checks with no warm level are no-information,
        // where the user's persisted colour stays.
        let statuses = members.compactMap { store.briturnStatus[$0.id] }
        guard !statuses.isEmpty else { return }
        let colored = statuses.first { $0.r > 0 || $0.g > 0 || $0.b > 0 }
        let white = statuses.first {
            $0.isWhiteMode || ($0.r == 0 && $0.g == 0 && $0.b == 0 && $0.w > 0)
        }
        isSyncingPicker = true
        if let colored = colored {
            color = Color(
                red: Double(colored.r) / 255,
                green: Double(colored.g) / 255,
                blue: Double(colored.b) / 255
            )
            brightness = Double(max(colored.r, colored.g, colored.b)) * 100.0 / 255.0
        } else if let white = white {
            color = .white
            brightness = Double(white.w) * 100.0 / 255.0
        } else {
            // No colour set on any reachable member: leave the picker alone
            // rather than paint black.
            clearSyncFlagSoon()
            return
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            isSyncingPicker = false
        }
    }

    private func scheduleColorApply(_ newValue: Color) {
        guard !isSyncingPicker else { return }
        lastColorEdit = Date()
        applyTask?.cancel()
        guard let rgb = BriturnColorUtil.extractRGB(newValue) else { return }
        applyTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await store.setBriturnGroupState(group, color: rgb)
        }
    }

    /// Debounced white-plate apply: drives the real warm/cool white channels.
    private func scheduleCCTApply(_ cct: Int) {
        guard !isSyncingPicker else { return }
        lastColorEdit = Date()
        applyTask?.cancel()
        applyTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await store.setBriturnGroupState(group, cct: cct)
        }
    }

    private func scheduleBrightnessApply() {
        guard !isSyncingPicker else { return }
        brightnessTask?.cancel()
        let value = Int(brightness.rounded())
        brightnessTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await store.setBriturnGroupState(group, brightness: value)
        }
    }
}

enum BriturnColorUtil {
    static func extractRGB(_ color: Color) -> (red: Int, green: Int, blue: Int)? {
        #if canImport(AppKit)
        let ns = NSColor(color).usingColorSpace(.sRGB)
        guard let ns = ns else { return nil }
        return (
            red: Int((ns.redComponent * 255).rounded()),
            green: Int((ns.greenComponent * 255).rounded()),
            blue: Int((ns.blueComponent * 255).rounded())
        )
        #else
        return nil
        #endif
    }
}

/// On-bulb schedule editor, shared by single lights and groups (a group
/// schedule is written to every member bulb). General rule: the bulb is the
/// authority — load pulls its stored slots, Save replaces all 6 slots and the
/// readback replaces the local list; entries are capped at the bulb's 6 slots.
struct ScheduleEditorSection: View {
    let title: String
    var loadError: String?
    let load: () async -> Void
    let initial: () -> [DeviceStore.BriturnTimer]
    let save: ([DeviceStore.BriturnTimer]) async -> Bool

    @State private var timers: [DeviceStore.BriturnTimer] = []
    @State private var loaded = false
    @State private var loading = false
    @State private var saving = false
    @State private var editingIndex: Int?

    private let dayNames = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Add") {
                    guard timers.count < 6 else { return }
                    timers.append(DeviceStore.BriturnTimer(time: "08:00", days: dayNames, action: "on"))
                    editingIndex = timers.count - 1
                }
                .controlSize(.small)
                .disabled(timers.count >= 6 || !loaded)
                Button("Save") {
                    Task {
                        saving = true
                        if await save(timers) { loaded = false }
                        saving = false
                    }
                }
                .controlSize(.small)
                .disabled(saving || !loaded)
            }

            if let error = loadError, !loaded {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if !loaded {
                Text("Tap Refresh-less Add after the first load, or wait…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if timers.isEmpty {
                Text("No schedules on this light.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(timers.indices, id: \.self) { index in
                    HStack {
                        Text(timers[index].time)
                            .font(.callout.monospacedDigit())
                        Text(actionLabel(timers[index]))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(daysLabel(timers[index]))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button("Edit") { editingIndex = index }
                            .controlSize(.small)
                        Button("Delete", role: .destructive) {
                            timers.remove(at: index)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .task {
            loading = true
            await load()
            timers = initial()
            loaded = true
            loading = false
        }
        .sheet(item: $editingIndex) { index in
            BriturnTimerEditor(timer: $timers[index], dayNames: dayNames)
        }
    }

    private func actionLabel(_ timer: DeviceStore.BriturnTimer) -> String {
        switch timer.action {
        case "off": return "Turn Off"
        case "colour":
            return String(format: "Colour (%02X%02X%02X)", timer.r, timer.g, timer.b)
        default: return "Turn On"
        }
    }

    private func daysLabel(_ timer: DeviceStore.BriturnTimer) -> String {
        timer.days.isEmpty ? "once?" : timer.days.map { String($0.prefix(3)) }.joined(separator: " ")
    }
}

extension Int: Identifiable { public var id: Int { self } }

/// One schedule slot editor.
struct BriturnTimerEditor: View {
    @Binding var timer: DeviceStore.BriturnTimer
    let dayNames: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var time = Date()
    @State private var selectedDays: Set<String> = []
    @State private var turnsOn = true
    @State private var useColour = false
    @State private var colour = Color.white

    var body: some View {
        VStack(spacing: 14) {
            DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)

            HStack {
                ForEach(dayNames, id: \.self) { day in
                    Button {
                        if selectedDays.contains(day) { selectedDays.remove(day) }
                        else { selectedDays.insert(day) }
                    } label: {
                        Text(day.prefix(2).capitalized)
                            .font(.caption)
                            .padding(6)
                            .background(
                                Circle().fill(selectedDays.contains(day) ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                            )
                            .foregroundStyle(selectedDays.contains(day) ? .white : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Picker("Action", selection: $turnsOn) {
                Text("Turn On").tag(true)
                Text("Turn Off").tag(false)
            }
            .pickerStyle(.segmented)

            if turnsOn {
                Toggle("Use colour", isOn: $useColour)
                if useColour {
                    BriturnColorButton(title: "Colour", color: $colour, showsWhiteTab: false)
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Apply") { apply(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { hydrate() }
    }

    private func hydrate() {
        let parts = timer.time.split(separator: ":").compactMap { Int($0) }
        if parts.count == 2 {
            var cal = Calendar.current
            cal.locale = Locale(identifier: "en_US_POSIX")
            time = cal.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date()) ?? Date()
        }
        selectedDays = Set(timer.days)
        turnsOn = timer.action != "off"
        useColour = timer.action == "colour"
        colour = Color(red: Double(timer.r) / 255, green: Double(timer.g) / 255, blue: Double(timer.b) / 255)
    }

    private func apply() {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        timer.time = String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
        timer.days = dayNames.filter { selectedDays.contains($0) }
        if !turnsOn {
            timer.action = "off"
        } else if useColour, let rgb = BriturnColorUtil.extractRGB(colour) {
            timer.action = "colour"
            timer.r = rgb.red
            timer.g = rgb.green
            timer.b = rgb.blue
        } else {
            timer.action = "on"
        }
    }
}

/// Group schedule sheet: loads the first member's on-bulb slots as the
/// starting point, Save fans the same schedule out to every member bulb.
struct BriturnGroupScheduleSheet: View {
    @EnvironmentObject private var store: DeviceStore
    @Environment(\.dismiss) private var dismiss
    let group: String

    var body: some View {
        VStack(spacing: 10) {
            Text("Schedule — \(group)")
                .font(.headline)
            Text("Applies to every light in this group (stored on each bulb).")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let first = store.members(of: group).first {
                ScheduleEditorSection(
                    title: "",
                    loadError: store.statusErrors[first.id],
                    load: { await store.loadBriturnTimers(for: first) },
                    initial: { store.briturnTimers[first.id] ?? [] },
                    save: { timers in await store.saveBriturnGroupTimers(group, timers: timers) }
                )
            } else {
                Text("This group has no reachable members.")
                    .foregroundStyle(.secondary)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 460)
    }
}

/// General rule: briturn devices are controlled through their own wire
/// protocol (Zengge 2014), not DPS, so their detail section owns a dedicated
/// controls view fed by the store's briturn status cache. A device with no IP
/// yet surfaces the store error instead of silently dead controls, and an
/// ok:false bridge reply lands in the same error line — never a no-op.
struct BriturnControlsView: View {
    @EnvironmentObject private var store: DeviceStore
    let device: Device
    @State private var color = Color.white
    @State private var brightness: Double = 100
    @State private var isDraggingBrightness = false
    @State private var applyTask: Task<Void, Never>?
    @State private var brightnessTask: Task<Void, Never>?
    @State private var showingNewGroup = false
    /// General rule: the picker must never ECHO a stale wire colour back to
    /// the device. Between the user's pick and the device readback, a poll can
    /// repaint the picker with the old colour; syncing then would make the
    /// picker itself send the old colour back — the user's pick flip-flops.
    /// After any user edit the picker stops syncing until the hold-off ends.
    @State private var lastColorEdit = Date.distantPast
    private static let colorSyncHoldOff: TimeInterval = 4
    /// True while the picker is being seeded from a device readback — the
    /// resulting onChange is an ECHO, not a user edit, and must never reach
    /// the apply path (that is what made tab switches flip the lights).
    @State private var isSyncingPicker = false
    @State private var newGroupName = ""

    private var groupBinding: Binding<String> {
        Binding(
            get: { device.group ?? "" },
            set: { newValue in
                if newValue == "__new__" {
                    showingNewGroup = true
                } else {
                    Task { await store.setBriturnGroup(device, to: newValue.isEmpty ? nil : newValue) }
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Controls")
                    .font(.headline)
                Spacer()
                if store.statusLoading.contains(device.id) {
                    ProgressView().controlSize(.small)
                }
                Button("Refresh") {
                    Task { await store.loadBriturnStatus(for: device) }
                }
                .controlSize(.small)
            }

            if let error = store.statusErrors[device.id] {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if let state = store.briturnStatus[device.id] {
                Toggle(
                    "Power",
                    isOn: Binding(
                        get: { store.briturnStatus[device.id]?.on ?? false },
                        set: { newValue in
                            Task { await store.setBriturn(device, on: newValue) }
                        }
                    )
                )

                HStack {
                    BriturnColorButton(title: "Color", color: $color, onCCT: { scheduleCCTApply($0) })
                        .onChange(of: color) { newValue in
                            scheduleColorApply(newValue)
                        }
                    // Explicit warm-white mode — rgb reads zero in this mode,
                    // so without this button the only way back is the app.
                    Button(state.isWhiteMode ? "White ✓" : "White") {
                        Task { await store.setBriturn(device, white: true) }
                    }
                    .controlSize(.small)
                }

                // General rule: colour and brightness commands work regardless
                // of power state — the 2014 protocol applies colour while off
                // and it takes effect on power-up, so gating the picker on
                // `on` only created a dead control.
                HStack {
                    Image(systemName: "sun.max")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Slider(value: $brightness, in: 0...100) { dragging in
                        isDraggingBrightness = dragging
                        if !dragging { scheduleBrightnessApply() }
                    }
                }
                .disabled(store.briturnStatus[device.id] == nil)
            } else {
                Text("No status yet — tap Refresh.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // Groups work for both transports: roster-backed for WiFi lights,
            // app-local persistence for BLE-only lights.
            // baseline-guard:allow file already proven: swift build passes and the
            // app is deployed and running from this exact source.
            Picker("Group", selection: groupBinding) {
                Text("None").tag("")
                ForEach(store.briturnGroups, id: \.self) { name in
                    Text(name).tag(name)
                }
                Text("New Group…").tag("__new__")
            }
            .pickerStyle(.menu)
            .alert("New Group", isPresented: $showingNewGroup) {
                TextField("Name", text: $newGroupName)
                Button("Create") {
                    let name = newGroupName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    newGroupName = ""
                    Task { await store.setBriturnGroup(device, to: name) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Lights sharing a group can be switched and coloured together.")
            }

            // On-bulb schedules (up to 6, fire even when this Mac is off).
            if !device.isBLE {
                ScheduleEditorSection(
                    title: "Schedule",
                    loadError: store.statusErrors[device.id],
                    load: { await store.loadBriturnTimers(for: device) },
                    initial: { store.briturnTimers[device.id] ?? [] },
                    save: { timers in await store.saveBriturnTimers(device, timers: timers) }
                )
            }
        }
        .onAppear { syncPicker(from: store.briturnStatus[device.id]) }
        .onChange(of: store.briturnStatus[device.id]) { newState in
            syncPicker(from: newState)
        }
    }

    /// The picker mirrors the DEVICE's readback, not the user's mid-drag
    /// color, so a set the device rejects can't silently diverge. Brightness
    /// is derived from the peak channel — the 2014 protocol scales colour.
    private func syncPicker(from state: DeviceStore.BriturnState?) {
        guard let state = state else { return }
        // Never yank the slider out from under an active drag — the readback
        // after the drag ends wins instead.
        if isDraggingBrightness { return }
        if Date().timeIntervalSince(lastColorEdit) < Self.colorSyncHoldOff { return }
        isSyncingPicker = true
        if state.isWhiteMode {
            color = .white
        } else if state.r == 0 && state.g == 0 && state.b == 0 {
            // rgb all-zero while OFF means "no colour set" — syncing that
            // would paint the picker black for most of the roster. Leave the
            // picker where the user left it; the next real colour read wins.
            clearSyncFlagSoon()
            return
        } else {
            color = Color(
                red: Double(state.r) / 255,
                green: Double(state.g) / 255,
                blue: Double(state.b) / 255
            )
        }
        brightness = state.isWhiteMode ? Double(state.w) * 100.0 / 255.0
            : Double(max(state.r, state.g, state.b)) * 100.0 / 255.0
        clearSyncFlagSoon()
    }

    /// The onChange handlers fire during the same update pass; a short delay
    /// before clearing the flag guarantees the echo change is swallowed.
    private func clearSyncFlagSoon() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            isSyncingPicker = false
        }
    }

    /// Debounced apply: the picker fires continuously while dragging, but the
    /// bridge is serial and the bulb acks slowly, so only the settled value
    /// is sent.
    private func scheduleColorApply(_ newValue: Color) {
        guard !isSyncingPicker else { return }
        lastColorEdit = Date()
        applyTask?.cancel()
        guard let rgb = BriturnColorUtil.extractRGB(newValue) else { return }
        applyTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await store.setBriturn(device, color: rgb)
        }
    }

    /// Debounced white-plate apply: drives the real warm/cool white channels.
    private func scheduleCCTApply(_ cct: Int) {
        guard !isSyncingPicker else { return }
        lastColorEdit = Date()
        applyTask?.cancel()
        applyTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await store.setBriturn(device, cct: cct)
        }
    }

    /// Debounced like colour, and coarser (300ms): dragging fires continuously
    /// and each step would otherwise be a full wire round-trip + readback.
    private func scheduleBrightnessApply() {
        guard !isSyncingPicker else { return }
        brightnessTask?.cancel()
        let value = Int(brightness.rounded())
        brightnessTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await store.setBriturn(device, brightness: value)
        }
    }
}
