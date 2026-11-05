// Settings → Hotkey → "While listening": mute / duck / leave the speakers.
import MyHomeCore
import SwiftUI

struct OutputMuteSettingsSection: View {
    @ObservedObject var gate: ListeningOutputGate
    @AppStorage(AppSettings.listenOutputModeKey) private var mode = AppSettings.defaultListenOutputMode
    @AppStorage(AppSettings.listenDuckLevelKey) private var duckLevel = AppSettings.defaultListenDuckLevel
    @State private var capability: ListeningOutputGate.Capability?

    var body: some View {
        Section {
            Picker("Speaker output", selection: $mode) {
                Text("Off (leave as is)").tag(AppSettings.ListenOutputMode.off)
                Text("Mute").tag(AppSettings.ListenOutputMode.mute)
                Text("Duck (lower volume)").tag(AppSettings.ListenOutputMode.duck)
            }
            if mode == .duck {
                HStack {
                    Slider(value: $duckLevel, in: AppSettings.listenDuckLevelRange, step: AppSettings.listenDuckLevelStep)
                    Text("\(Int((duckLevel * 100).rounded()))% of current volume")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if mode != .off {
                HStack {
                    Button("Check this output") { capability = gate.probe() }
                    if let capability { Text(description(of: capability)).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if case .unsupported(let message) = gate.lastEngagement {
                Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("While listening")
        } footer: {
            Text("Silences music or video while the microphone is open and restores the exact previous volume afterwards (an output you had already muted stays muted). Bluetooth, AirPlay and HDMI outputs may have no mute control; MyHome then uses the volume, or tells you it cannot.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func description(of capability: ListeningOutputGate.Capability) -> String {
        switch capability {
        case .mute: return "This output supports mute."
        case .volumeOnly: return "No mute control; volume will be lowered instead."
        case .none: return "Cannot mute this output."
        case .noDevice: return ListeningOutputGate.noDeviceMessage
        }
    }
}
