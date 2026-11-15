// Settings → Hotkey → "Wake word": opt-in always-on listening for the wake
// phrase, the one-time model install, live state and sensitivity.
import MyHomeCore
import SwiftUI

struct WakeWordSettingsSection: View {
    @ObservedObject var wake: WakeWordListener
    @AppStorage(AppSettings.wakeWordThresholdKey) private var threshold = AppSettings.defaultWakeWordThreshold

    var body: some View {
        Section {
            Toggle("Listen for \u{201C}\(wake.phrase.capitalized)\u{201D}", isOn: Binding(
                get: { wake.enabled },
                set: { wake.setEnabled($0) }))
            if wake.enabled {
                stateRow
                VStack(alignment: .leading) {
                    Slider(value: $threshold, in: AppSettings.wakeWordThresholdRange) {
                        Text("Strictness")
                    } minimumValueLabel: {
                        Text("Eager").font(.caption)
                    } maximumValueLabel: {
                        Text("Strict").font(.caption)
                    } onEditingChanged: { editing in
                        if !editing { wake.reload() }
                    }
                    Text("Raise it if MyHome wakes by mistake; lower it if it misses you.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Wake word")
        } footer: {
            Text("Say the wake phrase, wait for the chime, then your command. Runs fully offline; the microphone stays on (orange dot) while armed and is released while MyHome listens to a command or speaks. Off by default.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var stateRow: some View {
        switch wake.state {
        case .off, .loading:
            Label("Starting…", systemImage: "hourglass").font(.caption)
        case .armed:
            Label("Listening for the wake phrase", systemImage: "ear").font(.caption).foregroundStyle(.green)
        case .paused:
            Label("Paused while MyHome is busy", systemImage: "pause.circle").font(.caption).foregroundStyle(.secondary)
        case .installing:
            Label("Downloading the wake-word model (~\(WakeWordModelSpec.approxDownloadMB) MB)…", systemImage: "arrow.down.circle").font(.caption)
        case .needsModel:
            HStack {
                Label("The wake-word model is not installed.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                Spacer()
                Button("Install (~\(WakeWordModelSpec.approxDownloadMB) MB)") { wake.installModelNow() }
            }
        case .unavailable(let reason):
            HStack {
                Label(reason, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                Spacer()
                Button("Retry") { wake.retry() }
            }
        }
    }
}
