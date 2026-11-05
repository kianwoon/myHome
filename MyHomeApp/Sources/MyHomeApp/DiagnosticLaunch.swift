// Diagnostic entry points that run text through the assistant (origins .url /
// .diagnostic — never accepted as a "yes"), so a change can be verified without clicks:
//   open "myhome://say?text=dim%20the%20study%20light"   (installed app)
//   MyHome --say "dim the study light"                    (launch argument)
//   MyHome --probe-tools                                  (tool-call probe)
// Both say forms are OFF by default (any local process can open a scheme):
// enable them in Settings → Housekeeper, or launch with MYHOME_DIAGNOSTICS=1.
import AppKit
import Foundation
import MyHomeCore

enum DiagnosticLaunch {
    static func run(arguments: [String], services: AppServices) {
        if let index = arguments.firstIndex(of: AppSettings.sayLaunchArgument), index + 1 < arguments.count {
            guard AppSettings.diagnosticSayAllowed() else {
                AppLog.assistant.notice("--say ignored: diagnostics disabled (Settings or MYHOME_DIAGNOSTICS=1)")
                return
            }
            let text = arguments[index + 1]
            let delay = AppSettings.sayLaunchDelay()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await services.sayForDiagnostics(text, via: "launch argument", origin: .diagnostic)
            }
        }
        if arguments.contains(AppSettings.probeLaunchArgument) {
            Task { @MainActor in await services.probeToolsForDiagnostics() }
        }
    }

    static func handle(_ url: URL, services: AppServices) {
        guard url.scheme?.lowercased() == AppSettings.sayURLScheme, url.host?.lowercased() == AppSettings.sayURLHost else {
            let scheme = url.scheme ?? "-", host = url.host ?? "-"
            AppLog.assistant.notice("ignored URL \(scheme, privacy: .public)://\(host, privacy: .public)")
            return
        }
        guard AppSettings.diagnosticSayAllowed() else {
            AppLog.assistant.notice("myhome://say ignored: diagnostics disabled (Settings or MYHOME_DIAGNOSTICS=1)")
            return
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let text = items.first(where: { $0.name == AppSettings.sayURLTextParameter })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            AppLog.assistant.notice("myhome://say ignored: no text")
            return
        }
        Task { @MainActor in await services.sayForDiagnostics(text, via: "url", origin: .url) }
    }
}
