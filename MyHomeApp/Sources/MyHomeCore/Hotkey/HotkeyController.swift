// Hold-to-talk state machine behind the global shortcut. The OS registration
// is injected (`HotkeyRegistering`) so press / release / repeat handling is
// unit tested offline; the Carbon implementation lives in the app target.
import Foundation

public enum HotkeyEvent: Equatable, Sendable { case pressed, released }

public enum HotkeyRegistrationError: Error, Equatable, LocalizedError {
    /// Another app (or macOS) already owns the combination.
    case conflict
    case failed(Int32)

    public var errorDescription: String? {
        switch self {
        case .conflict: return "That shortcut is already in use by another app or by macOS. Choose a different one."
        case .failed(let code): return "The shortcut could not be registered (system error \(code))."
        }
    }
}

@MainActor
public protocol HotkeyRegistering: AnyObject {
    /// Replaces any earlier registration. `handler` is called on the main thread.
    func register(_ binding: HotkeyBinding, handler: @escaping (HotkeyEvent) -> Void) throws
    func unregister()
}

@MainActor
public final class HotkeyController: ObservableObject {
    @Published public private(set) var binding: HotkeyBinding?
    @Published public private(set) var registrationError: String?
    /// True between an accepted press and its release.
    @Published public private(set) var isHeld = false

    public var onPress: (() -> Void)?
    public var onRelease: (() -> Void)?

    private let registrar: HotkeyRegistering
    private let defaults: UserDefaults
    private var suspended = false

    public init(registrar: HotkeyRegistering, defaults: UserDefaults = .standard) {
        self.registrar = registrar
        self.defaults = defaults
    }

    /// Loads the stored binding and registers it. Call once at launch.
    public func start() {
        binding = HotkeyBinding.load(from: defaults)
        applyRegistration()
    }

    /// Validates, persists and live re-registers. A rejected binding changes nothing.
    @discardableResult
    public func setBinding(_ new: HotkeyBinding?) -> HotkeyBinding.Validation {
        let verdict = new?.validate() ?? .ok
        guard verdict.isAcceptable else { return verdict }
        releaseIfHeld()
        HotkeyBinding.save(new, to: defaults)
        binding = new
        applyRegistration()
        return verdict
    }

    public func reset() { setBinding(AppSettings.defaultHotkeyBinding) }

    /// Unregisters while the Settings recorder listens, so the current shortcut
    /// does not swallow the keystroke being recorded.
    public func suspend() {
        guard !suspended else { return }
        suspended = true
        releaseIfHeld()
        registrar.unregister()
    }

    public func resume() {
        guard suspended else { return }
        suspended = false
        applyRegistration()
    }

    /// The key-up can be lost (sleep, lock screen, secure input). Treated as a release.
    public func cancelHeld() { releaseIfHeld() }

    func handle(_ event: HotkeyEvent) {
        switch event {
        case .pressed:
            guard !isHeld else { return }   // key repeat / duplicate press
            isHeld = true
            onPress?()
        case .released:
            guard isHeld else { return }    // release without a press
            isHeld = false
            onRelease?()
        }
    }

    private func releaseIfHeld() {
        guard isHeld else { return }
        isHeld = false
        onRelease?()
    }

    private func applyRegistration() {
        registrar.unregister()
        registrationError = nil
        guard !suspended, let binding else { return }
        do {
            try registrar.register(binding) { [weak self] event in self?.handle(event) }
        } catch {
            registrationError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
