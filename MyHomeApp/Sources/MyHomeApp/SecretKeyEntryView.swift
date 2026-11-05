// Renders SecretKeyEntryModel (MyHomeCore) for one API key: field with a Show
// toggle, the saved-key line read from the store, Save / Remove / Refresh, and a
// Test connection row. No key state lives here; the model owns every transition.
import AppKit
import MyHomeCore
import SwiftUI

struct SecretKeyEntryView: View {
    @ObservedObject var model: SecretKeyEntryModel
    let placeholder: String

    var body: some View {
        HStack {
            Group {
                if model.reveal {
                    TextField("API key", text: $model.fieldText, prompt: Text(placeholder))
                } else {
                    SecureField("API key", text: $model.fieldText, prompt: Text(placeholder))
                }
            }
            // Explicitly no content type (not a password/username field).
            .textContentType(nil)
            .autocorrectionDisabled()
            // A new identity after Save/Remove rebuilds the AppKit field empty.
            .id(model.fieldGeneration)
            Button { model.reveal.toggle() } label: {
                Image(systemName: model.reveal ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(model.reveal ? "Hide the typed key" : "Show the typed key")
        }
        if let typed = model.typedFingerprint {
            Text("Typed (not saved): ending \(typed)").font(.caption).foregroundStyle(.orange)
        }
        Text(model.savedLine()).font(.caption).foregroundStyle(.secondary)
        HStack {
            Button("Save key") { model.save() }.disabled(model.fieldText.isEmpty || model.phase == .saving)
            Button("Remove key") { model.remove() }.disabled(!model.hasStoredKey)
            Button("Refresh") { model.refresh() }.help("Re-read the saved key from the Keychain")
            Text(model.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }
}

/// "Test connection" for the SAVED key; `run` resolves the key from the store at call time.
struct SecretKeyTestRow: View {
    @ObservedObject var model: SecretKeyEntryModel
    let run: () async -> String

    var body: some View {
        HStack {
            Button(model.testing ? "Testing…" : "Test connection") { Task { await model.test(run) } }
                .disabled(model.testing)
            Text(model.testResult).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}
