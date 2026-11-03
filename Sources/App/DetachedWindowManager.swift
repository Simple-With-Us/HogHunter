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
        openDetachedWindow(store: store, initialTab: .overview, initialStorageSubTab: .apps, activateExisting: true)
    }

    /// Opens the standalone window on the Activity tab, where the full
    /// flagged-issues list sits above the process list.  The quick view's
    /// card shows three; this is where the rest are read and acted on.
    func openActivity(store: HogStore) {
        openDetachedWindow(store: store, initialTab: .activity, initialStorageSubTab: .apps, activateExisting: false)
        // An already-open window keeps its tab; bring it forward.
        if let existing = window {
            if existing.isMiniaturized {
                existing.deminiaturize(nil)
            }
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Opens the standalone window on the Disk Cleaner, so the quick view's
    /// Clean button lands where the cleanup runs instead of on Overview.
    func openCleaner(store: HogStore) {
        openDetachedWindow(store: store, initialTab: .storage, initialStorageSubTab: .clean, activateExisting: false)
        // An already-open window keeps its tab; bring it forward.
        if let existing = window {
            if existing.isMiniaturized {
                existing.deminiaturize(nil)
            }
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func openDetachedWindow(store: HogStore, initialTab: PanelTab, initialStorageSubTab: HogHunterPanel.StorageSubTab, activateExisting: Bool) {
        if let existing = window {
            if activateExisting {
                if existing.isMiniaturized {
                    existing.deminiaturize(nil)
                }
                existing.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }

        let size = NSSize(width: HogHunterPanel.dashboardWidth, height: HogHunterPanel.dashboardHeight)
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.isReleasedWhenClosed = false
        win.title = "Hog Hunter"
        win.contentMinSize = NSSize(width: HogHunterPanel.dashboardMinimumWidth, height: 580)

        let rootView = HogHunterPanel(initialTab: initialTab, initialStorageSubTab: initialStorageSubTab)
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
