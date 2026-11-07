// KEF speaker card + the shared control strip (card, detail panel and menu all
// use it). Every control goes through DeviceController.perform — the same
// command path as voice and text — and shows only CONFIRMED state.
import SwiftUI
import MyHomeCore

/// Status badge for a speaker (never conflates standby with offline).
enum KEFBadge {
    case connecting, active, standby, offline, needsSetup

    var title: String {
        switch self {
        case .connecting: return "Connecting"
        case .active: return "Active"
        case .standby: return "Standby"
        case .offline: return "Offline"
        case .needsSetup: return "Needs Setup"
        }
    }

    var symbol: String {
        switch self {
        case .connecting: return "ellipsis.circle"
        case .active: return "checkmark.circle.fill"
        case .standby: return "moon.zzz.fill"
        case .offline: return "wifi.slash"
        case .needsSetup: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .active: return .green
        case .standby: return .secondary
        case .connecting: return .secondary
        case .offline: return .red
        case .needsSetup: return .orange
        }
    }

    @MainActor
    static func of(_ device: Device, store: DeviceStore) -> KEFBadge {
        guard let reading = store.kefReading(for: device) else { return .connecting }
        if reading.lastError == .authenticationRequired { return .needsSetup }
        if reading.failures > 0 { return .offline }
        switch reading.state.power {
        case .active?: return .active
        case .standby?: return .standby
        default: return reading.lastSuccess == nil ? .connecting : .connecting
        }
    }
}

struct KEFBadgeView: View {
    let badge: KEFBadge
    let stale: Bool

    var body: some View {
        Label(stale ? "\(badge.title) · stale" : badge.title, systemImage: badge.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(badge.color)
            .accessibilityLabel("Status: \(badge.title)\(stale ? ", last known value" : "")")
    }
}

/// Runs commands for one speaker through the shared controller.
@MainActor
final class KEFCommandRunner: ObservableObject {
    @Published var error: String?
    private let controller = AppServices.shared.controller

    func run(_ command: DeviceCommand, on device: Device) async {
        let result = await controller.perform(command, on: DeviceQuery(ids: [device.id]), origin: .dashboard, confirmed: true)
        if let status = result.outcomes.first?.status {
            switch status {
            case .confirmed: error = nil
            default: error = status.reason
            }
        }
    }
}

struct KEFControls: View {
    @EnvironmentObject private var store: DeviceStore
    @StateObject private var runner = KEFCommandRunner()
    let device: Device
    @State private var preview: Double?
    @State private var dragging = false
    @State private var commitTask: Task<Void, Never>?

    private var state: KEFState? { store.kefState(for: device) }
    private var reading: KEFReading? { store.kefReading(for: device) }
    private var isActive: Bool { store.kefPower(for: device) == true }
    private var writable: Bool { store.reachability(for: device) != .offline && state != nil }
    private var stale: Bool { store.kefFreshness(for: device) != .fresh }
    private var ceiling: Double { Double(store.kefVolumeCeiling(for: device)) }
    private var pending: Set<KEFPendingControl> { reading?.pending ?? [] }

    private var powerBinding: Binding<Bool> {
        Binding(get: { isActive }, set: { on in Task { await runner.run(.power(on), on: device) } })
    }

    private var inputBinding: Binding<String> {
        Binding(get: { state?.input?.wireValue ?? "" },
                set: { value in Task { await runner.run(.input(value), on: device) } })
    }

    private func commit(_ value: Double) {
        let target = Int(value.rounded())
        Task {
            await runner.run(.volume(target), on: device)
            preview = nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Power")
                Spacer()
                if pending.contains(.power) { ProgressView().controlSize(.small) }
                Toggle(isActive ? "On" : "Standby", isOn: powerBinding)
                    .toggleStyle(.switch).labelsHidden()
                    .disabled(!writable)
                    .accessibilityLabel("Power")
                    .accessibilityValue(isActive ? "On" : "Standby")
                Text(isActive ? "On" : "Standby").font(.caption).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            }
            HStack {
                Text("Input")
                Spacer()
                if pending.contains(.input) { ProgressView().controlSize(.small) }
                Picker("Input", selection: inputBinding) {
                    if let input = state?.input, !KEFInput.selectable.contains(input) {
                        Text("Unknown").tag(input.wireValue)
                    }
                    ForEach(KEFInput.selectable, id: \.wireValue) { Text($0.label).tag($0.wireValue) }
                }
                .labelsHidden().frame(width: 130)
                .disabled(!writable || !isActive)
            }
            HStack(spacing: 8) {
                Text("Volume")
                Slider(value: Binding(
                    get: { preview ?? Double(state?.volume ?? 0) },
                    set: { newValue in
                        preview = newValue
                        // Dragging commits once on release; keyboard steps commit after a short quiet period.
                        guard !dragging else { return }
                        commitTask?.cancel()
                        commitTask = Task {
                            try? await Task.sleep(nanoseconds: UInt64(store.kefConfig.commitDebounce * 1_000_000_000))
                            guard !Task.isCancelled else { return }
                            commit(newValue)
                        }
                    }),
                    in: 0...max(ceiling, 1), step: 1,
                    onEditingChanged: { editing in
                        dragging = editing
                        if !editing, let preview { commitTask?.cancel(); commit(preview) }
                    })
                    .disabled(!writable || !isActive || state?.volume == nil)
                    .accessibilityLabel("Volume")
                Text(state?.volume == nil ? "–" : "\(Int((preview ?? Double(state?.volume ?? 0)).rounded()))%")
                    .monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            HStack {
                Button { Task { await runner.run(.volume(max((state?.volume ?? 0) - store.kefConfig.volumeStep, 0)), on: device) } } label: { Image(systemName: "minus") }
                    .accessibilityLabel("Volume down")
                Spacer()
                Button { Task { await runner.run(.mute(!(state?.muted ?? false)), on: device) } } label: {
                    Label(state?.muted == true ? "Unmute" : "Mute", systemImage: state?.muted == true ? "speaker.slash.fill" : "speaker.wave.2")
                }
                Spacer()
                Button {
                    let next = min((state?.volume ?? 0) + store.kefConfig.volumeStep, Int(ceiling))
                    Task { await runner.run(.volume(next), on: device) }
                } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Volume up")
            }
            .disabled(!writable || !isActive)
            if let error = runner.error ?? (reading?.lastError?.message) {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
        .disabled(false)
    }
}

struct KEFSpeakerCard: View {
    @EnvironmentObject private var store: DeviceStore
    let device: Device
    let isSelected: Bool
    let onSelect: () -> Void

    private var subtitle: String {
        let model = store.kefRecord(for: device)?.identity.model ?? "LS50 Wireless II"
        let display = KEFModel.isSupported(model) ? "LS50 Wireless II" : model
        return device.room.isEmpty ? display : "\(display) · \(device.room)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: DeviceKind.speaker.iconName).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                KEFBadgeView(badge: KEFBadge.of(device, store: store), stale: store.kefFreshness(for: device) == .stale)
            }
            KEFControls(device: device)
            HStack { Spacer(); Button("Details", action: onSelect).controlSize(.small) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(device.name), \(KEFBadge.of(device, store: store).title)")
    }
}
