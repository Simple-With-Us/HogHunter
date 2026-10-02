import AppKit
import SwiftUI

/// Manages macOS activation policy dynamically.
/// When auxiliary windows (Storage, Settings, Network) are open, Hog Hunter runs
/// as a regular application (.regular) with a visible Dock icon and Cmd+Tab presence.
/// When all auxiliary windows are closed, Hog Hunter returns to an accessory app
/// (.accessory) running exclusively in the menu bar.
@MainActor
final class AppActivationManager {
    static let shared = AppActivationManager()

    /// Which Hog Hunter window a registered window is, so a caller can ask for
    /// "the Settings window" instead of guessing from a title string.
    enum WindowRole {
        case settings
        case auxiliary
    }

    private var activeWindowTokens: Set<ObjectIdentifier> = []
    private var roles: [ObjectIdentifier: WindowRole] = [:]

    private init() {}

    func registerWindow(_ window: NSWindow, role: WindowRole = .auxiliary) {
        let token = ObjectIdentifier(window)
        roles[token] = role
        guard !activeWindowTokens.contains(token) else { return }
        activeWindowTokens.insert(token)
        updatePolicy()

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let window {
                    self.activeWindowTokens.remove(ObjectIdentifier(window))
                    self.roles.removeValue(forKey: ObjectIdentifier(window))
                }
                // Delay slightly so window.isVisible is updated by AppKit before rechecking
                DispatchQueue.main.async {
                    self.updatePolicy()
                }
            }
        }
    }

    /// The registered window playing `role`, if it is still open.  A closed
    /// window is dropped from `roles` on `willClose`, so this never returns a
    /// window the user has dismissed.
    func window(for role: WindowRole) -> NSWindow? {
        for window in NSApp.windows where roles[ObjectIdentifier(window)] == role {
            return window
        }
        return nil
    }

    func updatePolicy() {
        // A window counts if it is a visible standard titled window and not an NSPanel
        let hasOpenWindows = NSApp.windows.contains { window in
            window.isVisible && window.styleMask.contains(.titled) && !(window is NSPanel)
        }

        let targetPolicy: NSApplication.ActivationPolicy = hasOpenWindows ? .regular : .accessory
        if NSApp.activationPolicy() != targetPolicy {
            NSApp.setActivationPolicy(targetPolicy)
            if targetPolicy == .regular {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

/// NSViewRepresentable that attaches to any SwiftUI window view to register it
/// with AppActivationManager and ensure it is brought forward cleanly.
struct WindowActivator: NSViewRepresentable {
    var role: AppActivationManager.WindowRole = .auxiliary

    func makeNSView(context: Context) -> NSView {
        let view = ActivatingView()
        view.role = role
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func front() {
        DispatchQueue.main.async {
            AppActivationManager.shared.updatePolicy()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    final class ActivatingView: NSView {
        var role: AppActivationManager.WindowRole = .auxiliary

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            AppActivationManager.shared.registerWindow(window, role: role)
            DispatchQueue.main.async {
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }
}
