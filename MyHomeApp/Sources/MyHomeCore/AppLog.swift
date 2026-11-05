import Foundation
import os

/// Shared diagnostic loggers. Unlike NSLog, os.Logger lets call sites mark
/// non-secret fields `privacy: .public` so they are readable in `log show`.
/// Never log tokens, passwords, session ids, emails or API payloads.
enum AppLog {
    /// Fallback when the host process has no bundle identifier (e.g. tests).
    private static let fallbackSubsystem = "com.myhome.app"
    static let subsystem = Bundle.main.bundleIdentifier ?? fallbackSubsystem

    static let ble = Logger(subsystem: subsystem, category: "ble")
    static let store = Logger(subsystem: subsystem, category: "store")
    /// Unified control layer (resolver / policy / execution outcomes).
    static let control = Logger(subsystem: subsystem, category: "control")
    /// Voice, planner and intents adapters. Utterances are personal data:
    /// interpolate them with the default (private) privacy only.
    static let assistant = Logger(subsystem: subsystem, category: "assistant")
}
