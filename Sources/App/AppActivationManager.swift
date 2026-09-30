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

    private var activeWindowTokens: Set<ObjectIdentifier> = []

    private init() {}

    func registerWindow(_ window: NSWindow) {
        let token = ObjectIdentifier(window)
        guard !activeWindowTokens.contains(token) else { return }
        activeWindowTokens.insert(token)
        updatePolicy()

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            guard let self else { return }
            if let window {
                self.activeWindowTokens.remove(ObjectIdentifier(window))
            }
            // Delay slightly so window.isVisible is updated by AppKit before rechecking
            DispatchQueue.main.async {
                self.updatePolicy()
            }
        }
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
    func makeNSView(context: Context) -> NSView { ActivatingView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func front() {
        DispatchQueue.main.async {
            AppActivationManager.shared.updatePolicy()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    final class ActivatingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            AppActivationManager.shared.registerWindow(window)
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
