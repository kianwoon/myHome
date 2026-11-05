// Settings → Speech (engine choice, model install state) and Settings → Voice
// (Listening: VAD / endpointing) — the offline STT knobs. Every default and range comes from
// AppSettings (SpeechSettings.swift); changes apply to the next listen.
import MyHomeCore
import SwiftUI

struct SpeechEngineSettingsSection: View {
    @ObservedObject var speech: SpeechCommandRecognizer
    @AppStorage(AppSettings.speechPreferredEngineKey) private var preferred = AppSettings.defaultSpeechPreferredEngine
    @AppStorage(AppSettings.speechQwenAsrEnabledKey) private var qwenEnabled = AppSettings.defaultSpeechQwenAsrEnabled
    @AppStorage(AppSettings.speechSenseVoiceEnabledKey) private var senseVoiceEnabled = AppSettings.defaultSpeechSenseVoiceEnabled
    @AppStorage(AppSettings.speechUsePopModelsKey) private var usePop = AppSettings.defaultSpeechUsePopModels
    @AppStorage(AppSettings.speechHotwordBiasKey) private var hotwords = AppSettings.defaultSpeechHotwordBias

    var body: some View {
        Section {
            Picker("Engine", selection: $preferred) {
                Text("Automatic").tag("")
                ForEach(SpeechEngineKind.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Toggle("Use Qwen3-ASR", isOn: $qwenEnabled)
            Toggle("Use SenseVoice (fallback)", isOn: $senseVoiceEnabled)
            ForEach(SpeechEngineKind.allCases) { modelRow($0) }
            Toggle("Use models installed by Pop", isOn: $usePop)
            Toggle("Bias recognition toward device and room names", isOn: $hotwords)
        } header: {
            Text("Speech engine")
        } footer: {
            Text("Speech runs on this Mac with offline models (sherpa-onnx), the same ones the Pop app uses. "
                 + "Qwen3-ASR is tried first; SenseVoice takes over if it is missing or stops responding. "
                 + "Name biasing applies to Qwen3-ASR.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { speech.refreshSupport() }
        .onChange(of: preferred) { _ in speech.refreshSupport() }
        .onChange(of: qwenEnabled) { _ in speech.refreshSupport() }
        .onChange(of: senseVoiceEnabled) { _ in speech.refreshSupport() }
        .onChange(of: usePop) { _ in speech.refreshSupport() }
    }

    @ViewBuilder
    private func modelRow(_ kind: SpeechEngineKind) -> some View {
        HStack {
            Text("\(kind.label) model")
            Spacer()
            if let model = speech.installedModels[kind] {
                Text(model.source == .pop ? "Installed (from Pop)" : "Installed")
                    .foregroundStyle(.secondary)
                    .help(model.directory.path)
            } else if speech.installing.contains(kind) {
                ProgressView().controlSize(.small)
                Text("Downloading…").foregroundStyle(.secondary)
            } else {
                Text("Not installed").foregroundStyle(.secondary)
                Button("Install (~\(SpeechModelSpec.approxDownloadMB) MB)") { speech.installModel(kind) }
                    .help(SpeechModelStore.ownDirectory(kind).path)
            }
        }
    }
}

struct SpeechListeningSettingsSection: View {
    @AppStorage(AppSettings.speechVADThresholdKey) private var threshold = AppSettings.defaultSpeechVADThreshold
    @AppStorage(AppSettings.speechVADMinSilenceKey) private var minSilence = AppSettings.defaultSpeechVADMinSilence
    @AppStorage(AppSettings.speechEndpointHangoverKey) private var hangover = AppSettings.defaultSpeechEndpointHangover
    @AppStorage(AppSettings.speechNoSpeechTimeoutKey) private var noSpeech = AppSettings.defaultSpeechNoSpeechTimeout
    @AppStorage(AppSettings.speechMaxUtteranceKey) private var maxUtterance = AppSettings.defaultSpeechMaxUtterance

    var body: some View {
        Section {
            slider("Speech threshold", value: $threshold, range: AppSettings.speechVADThresholdRange, format: "%.2f")
            slider("Pause that splits a phrase", value: $minSilence, range: AppSettings.speechVADMinSilenceRange, format: "%.2fs")
            slider("Wait after speaking before acting", value: $hangover, range: AppSettings.speechEndpointHangoverRange, format: "%.1fs")
            slider("Give up when nothing is said", value: $noSpeech, range: AppSettings.speechNoSpeechTimeoutRange, format: "%.0fs")
            slider("Longest command", value: $maxUtterance, range: AppSettings.speechMaxUtteranceRange, format: "%.0fs")
        } header: {
            Text("Listening")
        } footer: {
            Text("Voice activity detection (Silero) ends a command automatically. Applies to the next command.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .monospacedDigit()
                .frame(minWidth: 44, alignment: .trailing)
        }
    }
}
