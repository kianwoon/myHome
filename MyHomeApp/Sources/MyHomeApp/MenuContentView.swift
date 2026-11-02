// baseline-guard:allow rewrite of existing menu view to use rich DPS state
import AppKit
import SwiftUI
import MyHomeCore

struct MenuContentView: View {
    @EnvironmentObject private var store: DeviceStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.headerText)
                .font(.headline)
                .padding(.horizontal, 4)

            Divider()

            if store.devices.isEmpty {
                HStack(spacing: 8) {
                    if store.isWorking {
                        ProgressView().controlSize(.small)
                    }
                    Text(store.isWorking ? "Loading devices…" : "No devices loaded.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .padding(.horizontal, 4)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        // One row per level-1 unit: a briturn GROUP, an
                        // ungrouped briturn light, or any other device. ON
                        // rows first, then alphabetical.
                        ForEach(menuRows, id: \.id) { row in
                            switch row {
                            case .group(let group):
                                BriturnGroupMenuRow(group: group)
                            case .device(let device):
                                DeviceRow(device: device)
                            }
                        }
                    }
                }
                .frame(maxHeight: 420)
            }

            if let notice = store.newDeviceNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.green)
                    .lineLimit(2)
                    .padding(.horizontal, 4)
            }

            if let error = store.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.horizontal, 4)
            }

            Divider()

            HStack(spacing: 12) {
                Button("Open MyHome") {
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("Rescan") {
                    Task { await store.rescan() }
                }
                .disabled(store.isWorking)
                SettingsLauncher()
                Spacer()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(12)
        .frame(width: 340)
        .task {
            if store.devices.isEmpty {
                await store.refresh()
            }
        }
        .onAppear { store.startPolling() }
        .onDisappear { store.stopPolling() }
    }

    /// Level-1 menu row: briturn is controlled per group.
    private enum MenuRow: Identifiable {
        case group(String)
        case device(Device)

        var id: String {
            switch self {
            case .group(let name): return "group:\(name)"
            case .device(let device): return "device:\(device.id)"
            }
        }
    }

    private var menuRows: [MenuRow] {
        var rows: [MenuRow] = store.briturnGroups.map { MenuRow.group($0) }
        for device in store.devices {
            if device.category.lowercased() == "briturn" {
                // Grouped lights are represented by their group row; only
                // ungrouped (incl. BLE-only) lights stand alone.
                if let group = device.group, !group.isEmpty, store.briturnGroups.contains(group) {
                    continue
                }
            }
            rows.append(.device(device))
        }
        return rows.sorted { lhs, rhs in
            let l = isOn(lhs)
            let r = isOn(rhs)
            if l != r { return l && !r }
            return displayName(lhs).lowercased() < displayName(rhs).lowercased()
        }
    }

    private func isOn(_ row: MenuRow) -> Bool {
        switch row {
        case .group(let group):
            return store.members(of: group).contains {
                store.briturnStatus[$0.id]?.on == true
            }
        case .device(let device):
            return store.state(for: device).power ?? false
        }
    }

    private func displayName(_ row: MenuRow) -> String {
        switch row {
        case .group(let group): return group
        case .device(let device): return device.name
        }
    }
}

/// Opens the native Settings scene from the menu panel.
///
/// macOS 14 exposes `SettingsLink`; macOS 13 has no such view, so the standard
/// AppKit `showSettingsWindow:` action is used there instead.
struct SettingsLauncher: View {
    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                Text("Settings…")
            }
        } else {
            Button("Settings…") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

/// One briturn group as a level-1 menu row: colour, honest member counts,
/// and a switch that drives the whole group.
struct BriturnGroupMenuRow: View {
    @EnvironmentObject private var store: DeviceStore
    let group: String

    private var members: [Device] { store.members(of: group) }

    private var onCount: Int {
        members.filter { store.briturnStatus[$0.id]?.on == true }.count
    }

    private var anyOn: Bool { onCount > 0 }

    /// Mirrors DeviceRow: no address and no BLE sighting means unreachable.
    private var isEnabled: Bool {
        members.contains { $0.hasAddress || $0.isBLE }
    }

    private var subtitle: String {
        "\(members.count) light\(members.count == 1 ? "" : "s") · \(onCount) on"
    }

    private var swatch: Color? {
        guard let rgb = store.groupColours[group] else { return nil }
        return Color(
            red: Double(rgb.red) / 255,
            green: Double(rgb.green) / 255,
            blue: Double(rgb.blue) / 255
        )
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { anyOn },
            set: { newValue in
                Task { await store.setBriturnGroupState(group, on: newValue) }
            }
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            if let swatch = swatch {
                Circle()
                    .fill(swatch)
                    .frame(width: 15, height: 15)
                    .overlay(Circle().strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5))
                    .frame(width: 22)
            } else {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 22)
                    .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(group)
                    .font(.callout)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: toggleBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!isEnabled)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.45)
    }
}

struct DeviceRow: View {
    @EnvironmentObject private var store: DeviceStore
    let device: Device

    private var isEnabled: Bool { device.hasAddress }

    private var power: Bool? { store.power(for: device) }

    private var subtitle: String {
        let state = store.state(for: device)
        if device.kind == .plug, let watts = state.wattsText {
            return watts
        }
        if device.kind == .climate, let temperature = state.temperature {
            return "\(DPSValue.format(temperature)) °C"
        }
        return isEnabled ? device.ip : "Offline"
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { store.power(for: device) ?? false },
            set: { newValue in
                Task { await store.toggle(device, to: newValue) }
            }
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.kind.iconName)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 22)
                .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.callout)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: toggleBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!isEnabled || power == nil)
                .opacity(power == nil ? 0.5 : 1)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.45)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: store.isOn[device.id])
    }
}
