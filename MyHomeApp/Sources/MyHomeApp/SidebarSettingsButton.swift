// Settings shortcut pinned to the bottom of the main window's sidebar, so the
// Settings window is one click away without going through the menu bar.
import AppKit
import SwiftUI

struct SidebarSettingsButton: View {
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if #available(macOS 14.0, *) {
                SettingsLink { label }
                    .buttonStyle(.plain)
            } else {
                Button {
                    // macOS 13 has no SettingsLink; the standard AppKit action opens the Settings scene.
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                } label: { label }
                .buttonStyle(.plain)
            }
        }
        .background(.bar)
        .help("Open Settings (⌘,)")
    }

    private var label: some View {
        Label("Settings", systemImage: "gearshape")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
    }
}
