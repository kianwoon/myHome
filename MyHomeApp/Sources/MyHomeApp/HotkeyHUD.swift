// Feedback for the global hold-to-talk shortcut when no window is open: a
// small floating, NON-ACTIVATING panel (never steals focus from the frontmost
// app) showing Listening…, the live transcript, the result and — because
// model plans always need confirmation — Yes / No for a pending confirmation.
import AppKit
import Combine
import MyHomeCore
import SwiftUI

@MainActor
final class HotkeyHUD: ObservableObject {
    enum Phase: Equatable {
        case hidden, listening, working
        case message(String, isError: Bool)
    }

    @Published private(set) var phase: Phase = .hidden

    /// Set by AppServices (they run the same confirm path as the command bar).
    var onConfirm: (() -> Void)?
    var onDeny: (() -> Void)?

    let speech: SpeechCommandRecognizer
    let assistant: AssistantCoordinator
    private let defaults: UserDefaults
    private var panel: HotkeyHUDPanel?
    private var dismissTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    /// True from key-down until an utterance arrives (or the session ends empty).
    private var awaitingUtterance = false

    init(speech: SpeechCommandRecognizer, assistant: AssistantCoordinator, defaults: UserDefaults = .standard) {
        self.speech = speech
        self.assistant = assistant
        self.defaults = defaults
        speech.$status
            .receive(on: DispatchQueue.main)   // after finish() has delivered any utterance
            .sink { [weak self] status in self?.speechStatusChanged(status) }
            .store(in: &cancellables)
        assistant.$pending
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.pendingChanged() }
            .store(in: &cancellables)
    }

    var isActive: Bool { phase != .hidden }

    func begin() {
        awaitingUtterance = true
        setPhase(.listening)
    }

    func released() {
        if phase == .listening { setPhase(.working) }
    }

    /// Release arrived before the recogniser ever started (model loading /
    /// permission prompt): nothing to run, nothing to show.
    func abandon() {
        awaitingUtterance = false
        hide()
    }

    func utteranceReceived() {
        guard isActive else { return }
        awaitingUtterance = false
        setPhase(.working)
    }

    func show(_ reply: AssistantReply) {
        guard isActive else { return }
        setPhase(.message(reply.text, isError: reply.kind == .error))
        scheduleDismiss(confirming: assistant.hasPendingConfirmation)
    }

    func showMessage(_ text: String, isError: Bool = false) {
        awaitingUtterance = false
        setPhase(.message(text, isError: isError))
        scheduleDismiss(confirming: false)
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        phase = .hidden
        panel?.orderOut(nil)
    }

    private func speechStatusChanged(_ status: SpeechCommandRecognizer.Status) {
        guard awaitingUtterance, isActive else { return }
        switch status {
        case .unavailable(let reason): showMessage(reason, isError: true)
        case .idle: showMessage("Didn't catch that.")
        default: break
        }
    }

    private func pendingChanged() {
        // Answered (or cancelled) from elsewhere while the HUD waits for it.
        if case .message = phase, !assistant.hasPendingConfirmation { scheduleDismiss(confirming: false) }
    }

    private func setPhase(_ new: Phase) {
        dismissTask?.cancel()
        dismissTask = nil
        phase = new
        presentPanel()
    }

    private func scheduleDismiss(confirming: Bool) {
        dismissTask?.cancel()
        let seconds = confirming ? AppSettings.hotkeyHUDConfirmDismiss(from: defaults) : AppSettings.hotkeyHUDDismiss(from: defaults)
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func presentPanel() {
        let panel = self.panel ?? HotkeyHUDPanel(content: HotkeyHUDView(hud: self, speech: speech, assistant: assistant))
        self.panel = panel
        panel.refreshSizeAndPosition()
        panel.orderFrontRegardless()   // never makeKey / activate
        // Content height changes with the phase; re-measure after SwiftUI lays out.
        DispatchQueue.main.async { [weak panel] in panel?.refreshSizeAndPosition() }
    }
}

/// Borderless, non-activating, click-through-to-buttons panel above other windows.
final class HotkeyHUDPanel: NSPanel {
    private let host: NSHostingView<HotkeyHUDView>
    private static let width: CGFloat = 380
    private static let topInset: CGFloat = 80

    init(content: HotkeyHUDView) {
        host = NSHostingView(rootView: content)
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 60),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func refreshSizeAndPosition() {
        host.layoutSubtreeIfNeeded()
        let fitting = host.fittingSize
        let size = NSSize(width: Self.width, height: max(fitting.height, 44))
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height - Self.topInset,
                        width: size.width, height: size.height), display: true)
    }
}

struct HotkeyHUDView: View {
    @ObservedObject var hud: HotkeyHUD
    @ObservedObject var speech: SpeechCommandRecognizer
    @ObservedObject var assistant: AssistantCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch hud.phase {
            case .hidden:
                EmptyView()
            case .listening:
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill").foregroundStyle(Color.accentColor)
                    Text(speech.isListening ? "Listening…" : "Getting ready…").font(.headline)
                }
                if !speech.transcript.isEmpty {
                    Text(speech.transcript).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
            case .working:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(speech.transcript.isEmpty ? "Working…" : speech.transcript).font(.callout).lineLimit(3)
                }
            case .message(let text, let isError):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: isError ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(isError ? Color.red : Color.secondary)
                    Text(text).font(.callout).lineLimit(5).fixedSize(horizontal: false, vertical: true)
                }
                if assistant.hasPendingConfirmation {
                    HStack {
                        Spacer()
                        Button("No") { hud.onDeny?() }
                        Button("Yes") { hud.onConfirm?() }.buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(width: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
