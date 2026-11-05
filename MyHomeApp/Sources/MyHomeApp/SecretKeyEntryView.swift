// Renders SecretKeyEntryModel (MyHomeCore) for one API key. Two ways in, neither a
// SwiftUI SecureField / NSSecureTextField (macOS infers those as password fields even
// with contentType nil and offers Passwords AutoFill on them — Apple DTS, forum
// thread 821395): (A) "Paste key from clipboard" reads NSPasteboard once and shows a
// preview to confirm; (B) a plain NSTextField with AutoFill/completion/substitutions
// off, masked by a bullets overlay unless Show is on. The model owns every transition.
import AppKit
import MyHomeCore
import SwiftUI

/// The general pasteboard, read only when the user presses "Paste key from clipboard".
final class GeneralKeyPasteboard: KeyPasteboard {
    func string() -> String? { NSPasteboard.general.string(forType: .string) }
}

struct SecretKeyEntryView: View {
    @ObservedObject var model: SecretKeyEntryModel
    let placeholder: String
    private let pasteboard: KeyPasteboard = GeneralKeyPasteboard()

    var body: some View {
        HStack {
            Button("Paste key from clipboard") { model.loadFromClipboard(pasteboard) }
                .help("Reads the clipboard once and shows its length and ending before saving")
            Text("or type it:").font(.caption).foregroundStyle(.secondary)
            PlainKeyField(text: $model.fieldText, placeholder: placeholder, masked: !model.reveal)
                .frame(minWidth: 160)
            Button { model.reveal.toggle() } label: {
                Image(systemName: model.reveal ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(model.reveal ? "Hide the typed key" : "Show the typed key")
        }
        if let preview = model.clipboardPreviewLine {
            HStack {
                Text(preview).font(.caption)
                Button("Save") { model.confirmClipboardSave() }
                Button("Cancel") { model.cancelClipboard() }
            }
        }
        if let typed = model.typedFingerprint {
            Text("Typed (not saved): ending \(typed)").font(.caption).foregroundStyle(.orange)
        }
        Text(model.savedLine()).font(.caption).foregroundStyle(.secondary)
        if let audit = model.auditLine() {
            Text(audit).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        if !model.warning.isEmpty {
            Label(model.warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        }
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

/// A plain (non-secure) single-line NSTextField that the system has no reason to treat
/// as a password field: no content type, no completion, no substitutions or predictions.
/// When `masked`, the text is drawn clear and a bullets overlay shows its length only.
struct PlainKeyField: View {
    @Binding var text: String
    let placeholder: String
    let masked: Bool

    var body: some View {
        PlainKeyTextField(text: $text, placeholder: placeholder, masked: masked)
            .overlay(alignment: .leading) {
                if masked, !text.isEmpty {
                    Text(String(repeating: "\u{2022}", count: min(text.count, Self.maxBullets)))
                        .lineLimit(1)
                        .padding(.leading, Self.textInset)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }

    /// Bullets drawn for a masked key (longer keys are clipped by the field anyway).
    private static let maxBullets = 80
    /// Matches the rounded-bezel text inset so bullets sit where the text would.
    private static let textInset: CGFloat = 5
}

private struct PlainKeyTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let masked: Bool

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.bezelStyle = .roundedBezel
        field.isBordered = true
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.contentType = nil
        field.isAutomaticTextCompletionEnabled = false
        field.allowsCharacterPickerTouchBarItem = false
        field.allowsEditingTextAttributes = false
        field.importsGraphics = false
        field.setAccessibilityLabel("API key")
        apply(to: field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        // Only push model changes (Save/Remove clearing it); never fight an edit in progress.
        if field.stringValue != text { field.stringValue = text }
        apply(to: field)
    }

    private func apply(to field: NSTextField) {
        field.placeholderString = placeholder
        let color: NSColor = masked ? .clear : .labelColor
        if field.textColor != color { field.textColor = color }
        (field.currentEditor() as? NSTextView)?.textColor = color
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let editor = field.currentEditor() as? NSTextView else { return }
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isContinuousSpellCheckingEnabled = false
            editor.isGrammarCheckingEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticDataDetectionEnabled = false
            editor.isAutomaticLinkDetectionEnabled = false
            editor.isAutomaticTextCompletionEnabled = false
            editor.textColor = field.textColor
            if #available(macOS 14.0, *) { editor.inlinePredictionType = .no }
            if #available(macOS 15.0, *) { editor.writingToolsBehavior = .none }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
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
