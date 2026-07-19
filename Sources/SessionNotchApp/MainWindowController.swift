import AppKit
import SwiftUI

// A plain, always-visible floating window listing sessions. Unlike the status-item
// popover, this cannot be hidden behind a MacBook notch, so it's the reliable way
// to see the app on a crowded menu bar until the notch UI (Task 7) lands.
@MainActor
final class MainWindowController {
    private let window: NSWindow

    init(store: RegistryStore) {
        let hosting = NSHostingController(rootView: SessionListView(store: store))
        window = NSWindow(contentViewController: hosting)
        window.title = "SessionNotch"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 320, height: 220))
        window.center()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
