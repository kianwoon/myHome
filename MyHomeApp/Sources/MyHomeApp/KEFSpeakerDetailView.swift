// Detail panel: the same controls as the card plus identity, freshness and housekeeping.
import SwiftUI
import MyHomeCore

struct KEFSpeakerDetailView: View {
    @EnvironmentObject private var store: DeviceStore
    let device: Device
    @State private var editing: KEFSpeakerRecord?
    @State private var confirmRemove = false
    @State private var refreshing = false

    private var record: KEFSpeakerRecord? { store.kefRecord(for: device) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: DeviceKind.speaker.iconName).font(.largeTitle)
                    VStack(alignment: .leading) {
                        Text(device.name).font(.title2.weight(.semibold))
                        KEFBadgeView(badge: KEFBadge.of(device, store: store), stale: store.kefFreshness(for: device) == .stale)
                    }
                }
                KEFControls(device: device)
                Divider()
                if let record {
                    LabeledContent("Model", value: record.identity.model)
                    LabeledContent("Firmware", value: record.identity.firmware.isEmpty ? "–" : record.identity.firmware)
                    LabeledContent("Address", value: record.address)
                    LabeledContent("Room", value: record.room.isEmpty ? "–" : record.room)
                }
                LabeledContent("Last update", value: lastUpdate)
                HStack {
                    Button(refreshing ? "Refreshing…" : "Refresh") {
                        refreshing = true
                        Task { await store.refreshKEF(device.id, manual: true); refreshing = false }
                    }.disabled(refreshing)
                    Button("Edit Connection") { editing = record }
                    Spacer()
                    Button("Remove from MyHome", role: .destructive) { confirmRemove = true }
                }
            }
            .padding()
        }
        .sheet(item: $editing) { AddKEFSpeakerView(editing: $0).environmentObject(store) }
        .confirmationDialog("Remove \(device.name) from MyHome?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { store.removeKEFSpeaker(id: device.id) }
        } message: { Text("Only MyHome's local setup is deleted. The speaker is not reset or unpaired.") }
    }

    private var lastUpdate: String {
        guard let last = store.kefReading(for: device)?.lastSuccess else { return "Never" }
        return last.formatted(date: .omitted, time: .standard)
    }
}

/// Compact menu-bar row sharing the dashboard's state and command path.
struct KEFMenuRow: View {
    @EnvironmentObject private var store: DeviceStore
    @Environment(\.openWindow) private var openWindow
    @StateObject private var runner = KEFCommandRunner()
    let device: Device

    private var state: KEFState? { store.kefState(for: device) }
    private var active: Bool { store.kefPower(for: device) == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: DeviceKind.speaker.iconName)
                Text(device.name).lineLimit(1)
                Spacer()
                KEFBadgeView(badge: KEFBadge.of(device, store: store), stale: store.kefFreshness(for: device) == .stale)
            }
            HStack(spacing: 8) {
                Toggle("Power", isOn: Binding(get: { active }, set: { on in Task { await runner.run(.power(on), on: device) } }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                Button { Task { await runner.run(.volume(max((state?.volume ?? 0) - store.kefConfig.volumeStep, 0)), on: device) } } label: { Image(systemName: "minus") }
                    .accessibilityLabel("Volume down")
                Text(state?.volume.map { "\($0)%" } ?? "–").monospacedDigit().frame(minWidth: 36)
                Button {
                    let next = min((state?.volume ?? 0) + store.kefConfig.volumeStep, store.kefVolumeCeiling(for: device))
                    Task { await runner.run(.volume(next), on: device) }
                } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Volume up")
                Button { Task { await runner.run(.mute(!(state?.muted ?? false)), on: device) } } label: {
                    Image(systemName: state?.muted == true ? "speaker.slash.fill" : "speaker.wave.2")
                }
                .accessibilityLabel(state?.muted == true ? "Unmute" : "Mute")
                Spacer()
                Button("Open Details") { openWindow(id: "dashboard"); NSApp.activate(ignoringOtherApps: true) }
                    .controlSize(.small)
            }
            .disabled(store.reachability(for: device) == .offline || state == nil)
            if let error = runner.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
        }
        .padding(.vertical, 4).padding(.horizontal, 4)
    }
}
