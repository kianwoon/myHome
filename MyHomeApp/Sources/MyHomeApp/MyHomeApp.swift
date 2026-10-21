// baseline-guard:allow new source file, no prior baseline
import AppKit
import SwiftUI
import MyHomeCore

@main
struct MyHomeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = DeviceStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(store)
                // General rule: a MenuBarExtra .window panel must have fixed
                // geometry. Its hosting view stays alive while closed; with
                // content-driven height, every store write re-layouts it and,
                // alongside the dashboard window, the two hosts invalidate
                // each other (100% CPU render ping-pong, sampled in
                // DisplayList.ViewUpdater.update/updateInheritedView).
                .frame(width: 380, height: 520)
        } label: {
            ZStack {
                Image(systemName: "house")
                // General rule: a GUI defect in the main window needs a
                // click-free repro path; this diagnostic opens the dashboard
                // on launch when MYHOME_AUTOOPEN=1 and is inert otherwise.
                AutoOpenTrigger()
            }
        }
        .menuBarExtraStyle(.window)

        Window("MyHome", id: "dashboard") {
            DashboardView()
                .environmentObject(store)
        }
        // Fits the designed layout without dead space: 175pt sidebar + ~580pt
        // two-column device grid + 360pt detail pane + divider/chrome.
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: no Dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        BridgeClient.shared.stop()
    }
}

/// Diagnostic-only launch trigger: opens the dashboard without a click so the
/// main window's layout/polling behavior can be reproduced headlessly.
struct AutoOpenTrigger: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                guard ProcessInfo.processInfo.environment["MYHOME_AUTOOPEN"] == "1" else {
                    return
                }
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}
