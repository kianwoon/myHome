// baseline-guard:allow new source file, no prior baseline
import AppKit
import SwiftUI
import MyHomeCore

@main
struct MyHomeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // The one store in the process: shared with the App Intents and the
    // assistant through AppServices (see AppServices.swift).
    @StateObject private var store = AppServices.shared.store

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
                LaunchWarmup(store: store)
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
                .environmentObject(store)
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

/// Loads the device list and statuses as soon as the app launches. The menu-bar
/// label is built at launch, whereas the panel and dashboard contents only
/// exist once opened, so without this the bridge and device data stay idle
/// until the user clicks. Polling still starts and stops with the views. Also
/// opens the dashboard so a launch from /Applications visibly starts the app.
struct LaunchWarmup: View {
    @ObservedObject var store: DeviceStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
                await store.refresh()
                await store.loadAllStatuses()
                await store.runAutoScanLoop()
            }
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
                let environment = ProcessInfo.processInfo.environment
                if environment["MYHOME_AUTOOPEN"] == "1" {
                    // Diagnostic contract for the dashboard: MYHOME_GROUP /
                    // MYHOME_ROOM pick the section, and
                    // MYHOME_DASHBOARD_SNAPSHOT_PATH writes a PNG of that
                    // window after the first poll, so card-height changes can
                    // be reviewed without screen-recording permissions.
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        openWindow(id: "dashboard")
                        NSApp.activate(ignoringOtherApps: true)
                        if let path = environment["MYHOME_DASHBOARD_SNAPSHOT_PATH"], !path.isEmpty {
                            // Size BEFORE the first layout pass so the grid
                            // fills the window; resizing after layout leaves
                            // unrendered regions in cacheDisplay.
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            applySnapshotSize()
                            try? await Task.sleep(nanoseconds: 8_000_000_000)
                            writeDashboardSnapshot(to: path)
                        }
                    }
                }
                // Same diagnostic contract for Settings: MYHOME_SETTINGS=1
                // opens the Cloud tab, and MYHOME_SNAPSHOT_PATH writes a PNG
                // of the settings window so a UI change can be reviewed
                // without screen-recording permissions or manual clicks.
                if environment["MYHOME_SETTINGS"] == "1" {
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        NSApp.sendAction(Selector(("showSettingsWindow:")),
                                         to: nil, from: nil)
                        NSApp.activate(ignoringOtherApps: true)
                        if let path = environment["MYHOME_SNAPSHOT_PATH"], !path.isEmpty {
                            try? await Task.sleep(nanoseconds: 8_000_000_000)
                            writeKeyWindowSnapshot(to: path)
                        }
                    }
                }
            }
    }

    private func writeKeyWindowSnapshot(to path: String) {
        writeSnapshot(of: NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }), to: path)
    }

    /// Dashboard-only snapshot: pick the titled app window (the settings panel
    /// may also be present), falling back to the key window.
    /// Diagnostic sizing (MYHOME_SNAPSHOT_SIZE=WxH) so a multi-row dashboard
    /// fits in one uncropped capture; the layout itself is unchanged.
    private func applySnapshotSize() {
        guard let size = ProcessInfo.processInfo.environment["MYHOME_SNAPSHOT_SIZE"] else { return }
        let parts = size.lowercased().split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]),
              let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "MyHome" })
                ?? NSApp.keyWindow else { return }
        window.setContentSize(NSSize(width: width, height: height))
    }

    private func writeDashboardSnapshot(to path: String) {
        let window = NSApp.windows.first { $0.isVisible && $0.title == "MyHome" }
            ?? NSApp.keyWindow
            ?? NSApp.windows.first(where: { $0.isVisible })
        writeSnapshot(of: window, to: path)
    }

    private func writeSnapshot(of window: NSWindow?, to path: String) {
        guard let window,
              let view = window.contentView,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
