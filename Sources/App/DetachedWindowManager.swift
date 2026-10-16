import AppKit
import SwiftUI

/// Manages presenting Hog Hunter as a standalone, standard macOS window when
/// detached from the menu bar.
@MainActor
final class DetachedWindowManager {
    static let shared = DetachedWindowManager()

    private var window: NSWindow?

    private init() {}

    /// Opens or brings forward the standalone Hog Hunter window.
    func openDetachedWindow(store: HogStore) {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let size = NSSize(width: HogHunterPanel.panelWidth, height: HogHunterPanel.panelHeight)
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Hog Hunter"
        win.contentMinSize = NSSize(width: 580, height: 600)

        let rootView = HogHunterPanel()
            .environmentObject(store)
        win.contentViewController = NSHostingController(rootView: rootView)
        win.setContentSize(size)
        win.center()

        AppActivationManager.shared.registerWindow(win, role: .auxiliary)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.window = nil
            }
        }

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        AppActivationManager.shared.updatePolicy()
        self.window = win
    }

    /// Closes the detached standalone window (e.g. when re-attaching to the menu bar).
    func closeDetachedWindow() {
        window?.close()
        window = nil
        AppActivationManager.shared.updatePolicy()
    }
}
