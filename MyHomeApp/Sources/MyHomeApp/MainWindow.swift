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

struct DashboardView: View {
    @EnvironmentObject private var store: DeviceStore
    @State private var group: DeviceGroup = DeviceGroup.allCases.first { ProcessInfo.processInfo.environment["MYHOME_GROUP"] == $0.title.lowercased() } ?? .fans
    @State private var selectedID: String?
    // Which category's button started the current rescan (drives the spinner).
    // Local view state only; the working flag itself stays store.isWorking.
    @State private var rescanningGroup: DeviceGroup?

    private var filtered: [Device] {
        store.devices.filter { group.contains($0) }
    }

    private var selectedDevice: Device? {
        store.devices.first { $0.id == selectedID }
    }

    var body: some View {
        NavigationSplitView {
            List(DeviceGroup.allCases, selection: $group) { item in
                sidebarRow(item)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 175)
            .navigationTitle("MyHome")
        } content: {
            ScrollView {
                if group == .briturn {
                    BriturnGroupsBar()
                }
                if filtered.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: group.icon)
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No devices in \(group.title).")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 250), spacing: 14)],
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
            .navigationSplitViewColumnWidth(min: 480, ideal: 580)
            .navigationTitle(group.title)
        } detail: {
            if let device = selectedDevice {
                DeviceDetailView(device: device)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "hand.tap")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Select a device to inspect its DPS.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            if store.devices.isEmpty {
                await store.refresh()
            }
            await store.loadAllStatuses()
            // Briturn statuses otherwise wait for the first poll cycle
            // (~10s), leaving the on-count and chips wrong at launch.
            await store.loadAllBriturnStatuses()
        }
        .onAppear { store.startPolling() }
        .onDisappear { store.stopPolling() }
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

    private var isBriturn: Bool { device.category.lowercased() == "briturn" }

    private var isEnabled: Bool { device.hasAddress }

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
            // you grouped lights precisely so they read as a set.
            let state = store.briturnStatus[device.id]
            let powerText = state.map { $0.on ? "On" : "Off" } ?? "Briturn"
            if let name = device.group, !name.isEmpty {
                return powerText + " · " + name
            }
            return powerText
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
                            .lineLimit(1)
                        CloudStatusBadge(online: store.cloudOnline[device.id])
                    }
                    HStack(spacing: 6) {
                        Text(summary(state))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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
        }
        .sheet(isPresented: $showingRename) {
            RenameSheet(device: device)
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
            LightControlView(device: device, state: state)
        case .plug:
            PlugReadoutView(state: state)
        case .climate:
            ClimateChipsView(state: state)
        default:
            RawPreviewView(state: state, kind: device.kind)
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

    private var state: DeviceState { store.state(for: device) }

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
                        Text(device.hasAddress ? device.ip : "No IP")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Rename…") { showingRename = true }
                        .controlSize(.small)
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
    }
}

/// General rule: groups are presented INSIDE the Briturn category, not as
/// sidebar entries — the group count follows the roster, not the navigation,
/// and the two things you do with a group (all on/off, set a mood colour)
/// are one tap on the chip without opening anything. An empty roster shows
/// a hint that teaches assignment via the light's detail view.
struct BriturnGroupsBar: View {
    @EnvironmentObject private var store: DeviceStore

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
                    ForEach(store.briturnGroups, id: \.self) { group in
                        BriturnGroupCard(group: group)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
    }
}

struct BriturnGroupCard: View {
    @EnvironmentObject private var store: DeviceStore
    let group: String
    @State private var color = Color(red: 1, green: 0, blue: 0)
    @State private var brightness: Double = 100
    @State private var isDraggingBrightness = false
    @State private var applyTask: Task<Void, Never>?
    @State private var brightnessTask: Task<Void, Never>?
    @State private var syncedGroup: String?
    /// Same anti-echo rule as the single-light picker: never let a stale wire
    /// colour repaint the well and get sent back as a user command.
    @State private var lastColorEdit = Date.distantPast
    private static let colorSyncHoldOff: TimeInterval = 4
    @State private var isSyncingPicker = false

    private var members: [Device] { store.members(of: group) }
    private var anyOn: Bool { members.contains { store.briturnStatus[$0.id]?.on == true } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text("\(members.count) light\(members.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                ColorPicker("", selection: $color, supportsOpacity: false)
                    .labelsHidden()
                    .onChange(of: color) { newValue in
                        scheduleColorApply(newValue)
                    }
            }
            HStack(spacing: 6) {
                Image(systemName: "sun.max")
                    .foregroundStyle(.secondary)
                    .font(.caption2)
                Slider(value: $brightness, in: 0...100, step: 1) { dragging in
                    isDraggingBrightness = dragging
                    if !dragging { scheduleBrightnessApply() }
                }
                .controlSize(.mini)
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
        .onAppear { syncPicker() }
        .onChange(of: store.briturnStatus) { _ in
            if syncedGroup != group { syncPicker() }
        }
    }

    /// Picker mirrors any member's colour; the device readback wins, same as
    /// the single-light path. Never yanked mid-drag.
    private func syncPicker() {
        if isDraggingBrightness { return }
        if Date().timeIntervalSince(lastColorEdit) < Self.colorSyncHoldOff { return }
        guard let member = members.first,
              let state = store.briturnStatus[member.id] else { return }
        syncedGroup = group
        isSyncingPicker = true
        color = Color(
            red: Double(state.r) / 255,
            green: Double(state.g) / 255,
            blue: Double(state.b) / 255
        )
        brightness = Double(max(state.r, state.g, state.b)) * 100.0 / 255.0
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

/// General rule: briturn devices are controlled through their own wire
/// protocol (Zengge 2014), not DPS, so their detail section owns a dedicated
/// controls view fed by the store's briturn status cache. A device with no IP
/// yet surfaces the store error instead of silently dead controls, and an
/// ok:false bridge reply lands in the same error line — never a no-op.
struct BriturnControlsView: View {
    @EnvironmentObject private var store: DeviceStore
    let device: Device
    @State private var color = Color(red: 1, green: 0, blue: 0)
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

                ColorPicker("Color", selection: $color, supportsOpacity: false)
                    .onChange(of: color) { newValue in
                        scheduleColorApply(newValue)
                    }

                // General rule: colour and brightness commands work regardless
                // of power state — the 2014 protocol applies colour while off
                // and it takes effect on power-up, so gating the picker on
                // `on` only created a dead control.
                HStack {
                    Image(systemName: "sun.max")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Slider(value: $brightness, in: 0...100, step: 1) { dragging in
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
        color = Color(
            red: Double(state.r) / 255,
            green: Double(state.g) / 255,
            blue: Double(state.b) / 255
        )
        brightness = Double(max(state.r, state.g, state.b)) * 100.0 / 255.0
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
