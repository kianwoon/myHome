import AppKit
import Carbon
import MyHomeCore

/// How this process was launched. A launch at login (Settings → Launch at
/// login, `SMAppService.mainApp`) must not pop the dashboard; a manual launch
/// from Finder/Dock still does.
///
/// Signal: the open-application Apple event carries `keyAEPropData` ==
/// `keyAELaunchedAsLogInItem` when loginwindow starts the app. It is only
/// readable during the launch delegate callbacks, hence `capture(stage:)`.
/// Diagnostic override: MYHOME_LOGIN_LAUNCH=1 forces the login path, =0 the
/// manual path.
enum LaunchContext {
    static let overrideEnvironmentKey = "MYHOME_LOGIN_LAUNCH"

    private(set) static var launchedAsLoginItem = false

    static func capture(stage: String) {
        if let forced = ProcessInfo.processInfo.environment[overrideEnvironmentKey] {
            launchedAsLoginItem = forced == "1"
            AppLog.store.notice("launch[\(stage, privacy: .public)]: override=\(forced, privacy: .public) loginItem=\(launchedAsLoginItem, privacy: .public)")
            return
        }
        guard let event = NSAppleEventManager.shared().currentAppleEvent else {
            AppLog.store.notice("launch[\(stage, privacy: .public)]: no current Apple event loginItem=\(launchedAsLoginItem, privacy: .public)")
            return
        }
        let property = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
        let isLogin = event.eventClass == AEEventClass(kCoreEventClass)
            && event.eventID == AEEventID(kAEOpenApplication)
            && property == OSType(keyAELaunchedAsLogInItem)
        // Sticky: once either callback sees the login marker, keep it.
        launchedAsLoginItem = launchedAsLoginItem || isLogin
        AppLog.store.notice("launch[\(stage, privacy: .public)]: eventID=\(event.eventID, privacy: .public) propData=\(property ?? 0, privacy: .public) loginItem=\(launchedAsLoginItem, privacy: .public)")
    }
}
