// Settings → Hotkey → "Hold-to-talk shortcut": click-to-record field,
// Clear / Reset, validation and registration-error text.
import AppKit
import MyHomeCore
import SwiftUI

struct HotkeySettingsSection: View {
    @ObservedObject var hotkey: HotkeyController
    @State private var recording = false
    @State private var rejection: String?

    var body: some View {
        Section {
            HStack {
                Text("Shortcut")
                Spacer()
                ShortcutRecorder(binding: hotkey.binding,
                                 onRecordingChange: { active in
                                     recording = active
                                     if active { rejection = nil; hotkey.suspend() } else { hotkey.resume() }
                                 },
                                 onCapture: capture)
                    .frame(width: 170, height: 24)
                Button("Clear") { rejection = nil; hotkey.setBinding(nil) }
                    .disabled(hotkey.binding == nil)
                Button("Reset") { rejection = nil; hotkey.reset() }
                    .disabled(hotkey.binding == AppSettings.defaultHotkeyBinding)
            }
            if let rejection {
                Label(rejection, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
            } else if let warning = hotkey.binding?.validate().message {
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if let error = hotkey.registrationError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Hold-to-talk shortcut")
        } footer: {
            Text(recording ? "Press the new shortcut, or Esc to cancel."
                           : "Hold to talk, release to run. Works from any app. It only starts listening; confirmations and safety checks are unchanged. Not set by default.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onDisappear { if recording { hotkey.resume() } }
    }

    private func capture(_ binding: HotkeyBinding) {
        let verdict = hotkey.setBinding(binding)
        if case .rejected(let reason) = verdict { rejection = reason } else { rejection = nil }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    var binding: HotkeyBinding?
    var onRecordingChange: (Bool) -> Void
    var onCapture: (HotkeyBinding) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.bezelStyle = .rounded
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.binding = binding
        button.onRecordingChange = onRecordingChange
        button.onCapture = onCapture
        button.refreshTitle()
    }
}

final class RecorderButton: NSButton {
    var binding: HotkeyBinding?
    var onRecordingChange: ((Bool) -> Void)?
    var onCapture: ((HotkeyBinding) -> Void)?
    private var isRecording = false
    private static let escapeKeyCode: UInt16 = 53

    override init(frame: NSRect) {
        super.init(frame: frame)
        target = self
        action = #selector(beginRecording)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    func refreshTitle() {
        title = isRecording ? "Press shortcut…" : (binding?.displayString ?? "Click to record")
    }

    @objc private func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        window?.makeFirstResponder(self)
        refreshTitle()
        onRecordingChange?(true)
    }

    private func endRecording() {
        guard isRecording else { return }
        isRecording = false
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        refreshTitle()
        onRecordingChange?(false)
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { DispatchQueue.main.async { [weak self] in self?.endRecording() } }
        return super.resignFirstResponder()
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        let held = Self.mask(from: event.modifierFlags)
        title = held == 0 ? "Press shortcut…" : String(HotkeyBinding(keyCode: 0, modifiers: held).displayString.dropLast()) + "…"
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        capture(event)
    }

    /// ⌘-combinations arrive here, not in keyDown.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        capture(event)
        return true
    }

    private func capture(_ event: NSEvent) {
        let mods = Self.mask(from: event.modifierFlags)
        if event.keyCode == Self.escapeKeyCode && mods == 0 { endRecording(); return }
        let captured = HotkeyBinding(keyCode: UInt32(event.keyCode), modifiers: mods)
        endRecording()
        onCapture?(captured)
    }

    private static func mask(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= HotkeyBinding.commandMask }
        if flags.contains(.shift) { mask |= HotkeyBinding.shiftMask }
        if flags.contains(.option) { mask |= HotkeyBinding.optionMask }
        if flags.contains(.control) { mask |= HotkeyBinding.controlMask }
        return mask
    }
}
