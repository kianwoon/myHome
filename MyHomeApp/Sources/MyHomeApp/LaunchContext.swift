import AppKit
import Carbon
import MyHomeCore

/// How this process was launched. A launch at login (Settings → Launch at
/// login, `SMAppService.mainApp`) must not pop the dashboard; a manual launch
/// from Finder/Dock/`open` still does.
///
/// Signal (from this app's own launch logs, macOS 27): a manual launch always
/// has an open-application (`oapp`) Apple event by `didFinishLaunching`; a
/// login launch has no Apple event at all. The classic
/// `keyAEPropData == keyAELaunchedAsLogInItem` marker is still honoured but was
/// never observed for an `SMAppService` login launch. The decision is made
/// only at `didFinishLaunching` — every launch, manual included, has no event
/// yet at `willFinishLaunching`.
/// Diagnostic override: MYHOME_LOGIN_LAUNCH=1 forces the login path, =0 the
/// manual path.
@MainActor
enum LaunchContext {
    static let overrideEnvironmentKey = "MYHOME_LOGIN_LAUNCH"
    static let decisionStage = "didFinishLaunching"

    private(set) static var launchedAsLoginItem = false
    private(set) static var isResolved = false
    private static var sawLoginMarker = false
    private static var waiters: [CheckedContinuation<Void, Never>] = []

    static func capture(stage: String) {
        let final = stage == decisionStage
        if let forced = ProcessInfo.processInfo.environment[overrideEnvironmentKey] {
            launchedAsLoginItem = forced == "1"
            AppLog.store.notice("launch[\(stage, privacy: .public)]: override=\(forced, privacy: .public) loginItem=\(launchedAsLoginItem, privacy: .public)")
            if final { resolve() }
            return
        }
        let event = NSAppleEventManager.shared().currentAppleEvent
        let property = event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
        if let event, event.eventClass == AEEventClass(kCoreEventClass),
           event.eventID == AEEventID(kAEOpenApplication),
           property == OSType(keyAELaunchedAsLogInItem) {
            sawLoginMarker = true
        }
        if final {
            launchedAsLoginItem = sawLoginMarker || event == nil
        }
        AppLog.store.notice("launch[\(stage, privacy: .public)]: event=\(event != nil, privacy: .public) eventID=\(event?.eventID ?? 0, privacy: .public) propData=\(property ?? 0, privacy: .public) loginMarker=\(sawLoginMarker, privacy: .public) final=\(final, privacy: .public) loginItem=\(launchedAsLoginItem, privacy: .public)")
        if final { resolve() }
    }

    /// Suspends until `didFinishLaunching` has decided the launch kind, so a
    /// scene task that runs earlier never reads an undecided flag.
    static func waitUntilResolved() async {
        if isResolved { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private static func resolve() {
        isResolved = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
