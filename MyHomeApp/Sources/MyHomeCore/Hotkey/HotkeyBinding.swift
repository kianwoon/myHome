// A global shortcut: virtual key code + modifier mask. Pure value type (no
// Carbon / AppKit import) so validation, display and persistence are unit
// tested offline. Modifier bits use Carbon's values so the app layer can pass
// `modifiers` straight to RegisterEventHotKey.
import Foundation

public struct HotkeyBinding: Codable, Equatable, Hashable, Sendable {
    public static let commandMask: UInt32 = 0x0100
    public static let shiftMask: UInt32 = 0x0200
    public static let optionMask: UInt32 = 0x0800
    public static let controlMask: UInt32 = 0x1000
    public static let allModifiers: UInt32 = commandMask | shiftMask | optionMask | controlMask

    public let keyCode: UInt32
    public let modifiers: UInt32

    /// Unrelated modifier bits (caps lock, fn…) are dropped.
    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.allModifiers
    }

    public enum Validation: Equatable {
        case ok
        /// Usable, but likely to clash; shown to the user.
        case warning(String)
        case rejected(String)

        public var isAcceptable: Bool {
            if case .rejected = self { return false }
            return true
        }

        public var message: String? {
            switch self {
            case .ok: return nil
            case .warning(let text), .rejected(let text): return text
            }
        }
    }

    // Key codes (kVK_*) used by the reserved list and the modifier-only guard.
    private static let space: UInt32 = 49, tab: UInt32 = 48, escape: UInt32 = 53
    private static let keyQ: UInt32 = 12, keyH: UInt32 = 4, key3: UInt32 = 20, key4: UInt32 = 21, key5: UInt32 = 23
    private static let modifierKeyCodes: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    /// Combinations macOS owns; registering them is refused or silently
    /// shadowed by the system, so the user gets a warning up front.
    private static let reserved: [(HotkeyBinding, String)] = [
        (HotkeyBinding(keyCode: space, modifiers: commandMask), "⌘Space is Spotlight"),
        (HotkeyBinding(keyCode: space, modifiers: commandMask | optionMask), "⌥⌘Space is Finder search"),
        (HotkeyBinding(keyCode: space, modifiers: controlMask), "⌃Space switches input source"),
        (HotkeyBinding(keyCode: tab, modifiers: commandMask), "⌘Tab is the app switcher"),
        (HotkeyBinding(keyCode: tab, modifiers: commandMask | shiftMask), "⇧⌘Tab is the app switcher"),
        (HotkeyBinding(keyCode: escape, modifiers: commandMask | optionMask), "⌥⌘Esc is Force Quit"),
        (HotkeyBinding(keyCode: keyQ, modifiers: commandMask), "⌘Q quits the frontmost app"),
        (HotkeyBinding(keyCode: keyQ, modifiers: commandMask | controlMask), "⌃⌘Q locks the screen"),
        (HotkeyBinding(keyCode: keyH, modifiers: commandMask), "⌘H hides the frontmost app"),
        (HotkeyBinding(keyCode: key3, modifiers: commandMask | shiftMask), "⇧⌘3 takes a screenshot"),
        (HotkeyBinding(keyCode: key4, modifiers: commandMask | shiftMask), "⇧⌘4 takes a screenshot"),
        (HotkeyBinding(keyCode: key5, modifiers: commandMask | shiftMask), "⇧⌘5 opens screenshot options")
    ]

    public func validate() -> Validation {
        if Self.modifierKeyCodes.contains(keyCode) {
            return .rejected("Pick a key together with the modifiers, not a modifier on its own.")
        }
        if modifiers == 0 {
            return .rejected("Include at least one modifier (⌃ ⌥ ⇧ ⌘) so normal typing is not hijacked.")
        }
        if let hit = Self.reserved.first(where: { $0.0 == self }) {
            return .warning("\(hit.1) — macOS may handle it before MyHome sees it.")
        }
        if modifiers == Self.shiftMask {
            return .warning("⇧ alone clashes with typing capital letters.")
        }
        return .ok
    }

    /// e.g. "⌥Space", "⌃⌥⇧⌘K".
    public var displayString: String {
        var text = ""
        if modifiers & Self.controlMask != 0 { text += "⌃" }
        if modifiers & Self.optionMask != 0 { text += "⌥" }
        if modifiers & Self.shiftMask != 0 { text += "⇧" }
        if modifiers & Self.commandMask != 0 { text += "⌘" }
        return text + Self.keyName(for: keyCode)
    }

    static func keyName(for code: UInt32) -> String {
        keyNames[code] ?? "Key \(code)"
    }

    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
        13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
        35: "P", 36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13", 107: "F14",
        109: "F10", 111: "F12", 113: "F15", 114: "Help", 115: "Home", 116: "Page Up", 117: "Forward Delete",
        118: "F4", 119: "End", 120: "F2", 121: "Page Down", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]

    // MARK: Persistence (UserDefaults, JSON)

    public static func load(from defaults: UserDefaults = .standard) -> HotkeyBinding? {
        guard let data = defaults.data(forKey: AppSettings.hotkeyBindingKey),
              let binding = try? JSONDecoder().decode(HotkeyBinding.self, from: data),
              binding.validate().isAcceptable else { return AppSettings.defaultHotkeyBinding }
        return binding
    }

    /// `nil` removes the stored value (back to the default).
    public static func save(_ binding: HotkeyBinding?, to defaults: UserDefaults = .standard) {
        guard let binding, let data = try? JSONEncoder().encode(binding) else {
            defaults.removeObject(forKey: AppSettings.hotkeyBindingKey)
            return
        }
        defaults.set(data, forKey: AppSettings.hotkeyBindingKey)
    }
}

public extension AppSettings {
    /// JSON-encoded `HotkeyBinding`; absent = no global shortcut.
    static let hotkeyBindingKey = "assistantHotkeyBinding"
    static let defaultHotkeyBinding: HotkeyBinding? = nil
    /// How long the hotkey HUD stays after a result.
    static let hotkeyHUDDismissKey = "hotkeyHUDDismissSeconds"
    static let defaultHotkeyHUDDismiss: TimeInterval = 4
    /// How long it stays while a confirmation (Yes / No) is pending.
    static let hotkeyHUDConfirmDismissKey = "hotkeyHUDConfirmDismissSeconds"
    static let defaultHotkeyHUDConfirmDismiss: TimeInterval = 15
    static let hotkeyHUDDismissRange: ClosedRange<TimeInterval> = 1...60

    static func hotkeyHUDDismiss(from defaults: UserDefaults = .standard) -> TimeInterval {
        hudSeconds(defaults, hotkeyHUDDismissKey, defaultHotkeyHUDDismiss)
    }

    static func hotkeyHUDConfirmDismiss(from defaults: UserDefaults = .standard) -> TimeInterval {
        hudSeconds(defaults, hotkeyHUDConfirmDismissKey, defaultHotkeyHUDConfirmDismiss)
    }

    private static func hudSeconds(_ defaults: UserDefaults, _ key: String, _ fallback: TimeInterval) -> TimeInterval {
        let stored = defaults.object(forKey: key) as? Double ?? fallback
        return min(max(stored, hotkeyHUDDismissRange.lowerBound), hotkeyHUDDismissRange.upperBound)
    }
}
