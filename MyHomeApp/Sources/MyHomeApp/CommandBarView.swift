// Voice / text command bar pinned under the dashboard. Everything it does
// goes through AssistantCoordinator → DeviceController; the view only
// renders replies and the two decisions a reply can leave open (confirm a
// multi-device plan, pick between ambiguous devices).
import MyHomeCore
import SwiftUI

struct CommandBarView: View {
    @ObservedObject private var assistant: AssistantCoordinator
    @ObservedObject private var speech: SpeechCommandRecognizer
    @ObservedObject private var responder: SpeechResponder
    @State private var text = ""
    @FocusState private var focused: Bool
    private let services: AppServices

    init(services: AppServices) {
        self.services = services
        _assistant = ObservedObject(wrappedValue: services.assistant)
        _speech = ObservedObject(wrappedValue: services.speech)
        _responder = ObservedObject(wrappedValue: services.responder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reply = assistant.replies.last {
                replyRow(reply)
            }
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(submit)
                    .disabled(assistant.isBusy)
                if assistant.isBusy {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { assistant.cancelActive() }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                }
                Button(action: toggleMicrophone) {
                    Image(systemName: speech.isListening ? "mic.fill" : "mic")
                        .foregroundStyle(speech.isListening ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!speech.isSupported)
                .help(microphoneHelp)
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }
            if case .unavailable(let reason) = speech.status {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if case .loadingModel(let engine) = speech.status {
                Text("Loading the \(engine) speech model…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .onChange(of: speech.transcript) { transcript in
            if speech.isListening { text = transcript }
        }
        .onChange(of: speech.isListening) { listening in
            // The utterance itself is run by AppServices; just drop the echo.
            if !listening { text = "" }
        }
    }

    private var placeholder: String {
        speech.isListening ? "Listening…" : "Try “turn off the bedroom lights” or “set the study fan to 50%”"
    }

    private var microphoneHelp: String {
        if !speech.isSupported {
            return SpeechCommandRecognizer.usageDescriptionsPresent(in: .main)
                ? "No offline speech model is installed — see Settings → Assistant → Speech engine."
                : "Voice input needs the Xcode-built app (microphone usage description)."
        }
        return speech.isListening ? "Stop listening (⇧⌘M)" : "Speak a command (⇧⌘M)"
    }

    @ViewBuilder
    private func replyRow(_ reply: AssistantReply) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon(for: reply.kind))
                .foregroundStyle(reply.kind == .error ? Color.red : Color.secondary)
            Text(reply.text)
                .font(.callout)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if assistant.hasPendingConfirmation {
                Button("Yes") { Task { await confirm() } }
                    .keyboardShortcut(.defaultAction)
                Button("No") { assistant.cancelPending() }
                    .keyboardShortcut(.cancelAction)
            } else if let choice = assistant.pendingChoice {
                ForEach(choice.candidates) { candidate in
                    Button(candidate.name) {
                        Task {
                            if let done = await assistant.choose(deviceID: candidate.id, origin: .text) {
                                responder.speak(done.text)
                            }
                        }
                    }
                }
            }
        }
        .controlSize(.small)
    }

    private func icon(for kind: AssistantReply.Kind) -> String {
        switch kind {
        case .executed: return "checkmark.circle"
        case .needsConfirmation, .ambiguous: return "questionmark.circle"
        case .status, .info: return "info.circle"
        case .planned: return "list.bullet"
        case .error: return "exclamationmark.triangle"
        }
    }

    private func submit() {
        let utterance = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !utterance.isEmpty else { return }
        text = ""
        Task { await send(utterance, origin: .text) }
    }

    private func send(_ utterance: String, origin: CommandOrigin) async {
        _ = await assistant.handle(utterance, origin: origin)
    }

    private func confirm() async {
        await services.confirmPending()
    }

    private func toggleMicrophone() {
        if speech.isListening {
            speech.stopListening()
        } else {
            responder.stop()
            speech.startListening()
        }
    }
}
