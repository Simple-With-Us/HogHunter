import SwiftUI

/** CI screenshot hook: launched with `-HogHunterScreenshot`, the app is an accessory whose
 *  initial scene is a `MenuBarExtra`, so nothing visible exists to capture. The delegate opens
 *  an NSWindow hosting SettingsView and orders it front so the capture lane photographs a real
 *  app window instead of the runner desktop. Every step is traced to stderr so a headless-runner
 *  miss shows WHICH layer failed. Inert without the flag. */
class HogHunterAppDelegate: NSObject, NSApplicationDelegate {
    private var screenshotWindow: NSWindow?

    private func screenshotLog(_ message: String) {
        // FileHandle.standardError.write is unbuffered - each line hits the log immediately.
        FileHandle.standardError.write(Data(("[HogHunterScreenshot] " + message + "\n").utf8))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.arguments.contains("-HogHunterScreenshot") else { return }
        screenshotLog("flag seen; applicationDidFinishLaunching fired (isActive=\(NSApp.isActive))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.screenshotLog("presenting Settings NSWindow directly")
            let win = NSWindow(
                contentRect: NSRect(x: 200, y: 200, width: 560, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = "Hog Hunter"
            let store = HogStore()
            let rootView = SettingsView()
                .environmentObject(store)
                .frame(width: 560, height: 480)
            win.contentViewController = NSHostingController(rootView: rootView)
            win.setContentSize(NSSize(width: 560, height: 480))
            // Headless runners presented this window title-bar-only (440x38) because
            // the tab content had no ideal height; never let it shrink below the UI.
            win.contentMinSize = NSSize(width: 560, height: 480)
            win.center()
            // Register with the activation manager via its existing API (the
            // windowOpened() member this called was never defined) so the app
            // flips to .regular while the window is open, then re-evaluate
            // AFTER ordering front: updatePolicy() only counts visible,
            // titled, non-panel windows.
            AppActivationManager.shared.registerWindow(win)
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            AppActivationManager.shared.updatePolicy()
            self.screenshotWindow = win
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let win = self?.screenshotWindow else { return }
                if let content = win.contentView, content.frame.height < 300 {
                    self?.screenshotLog("content laid out too small (\(content.frame.size)); resizing")
                    win.setContentSize(NSSize(width: 560, height: 480))
                }
                self?.screenshotLog("post-layout: frame=\(win.frame) content=\(win.contentView?.frame.size ?? .zero)")
            }
            self.screenshotLog("Settings NSWindow ordered front: isVisible=\(win.isVisible) frame=\(win.frame)")
        }
    }
}

@main
struct HogHunterApp: App {
    @NSApplicationDelegateAdaptor(HogHunterAppDelegate.self) private var appDelegate
    @StateObject private var store = HogStore()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            HogHunterPanel()
                .environmentObject(store)
        } label: {
            HStack(spacing: 5) {
                Image("HogProfile")
                    .renderingMode(.original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 15)
                if store.menuBarLabelMode == .sparkline {
                    CpuSparklineView(samples: store.recentCpuPercents)
                }
                Text(store.menuBarLabel)
                    .monospacedDigit()
            }
            .help(store.menuBarHelp)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Hog Hunter")
            .accessibilityValue(store.menuBarAccessibilityValue)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(store)
        }

        Window("Storage", id: "hoghunter.storage") {
            StorageView { store.runningBundleIdsSnapshot() }
        }
        .defaultSize(width: 560, height: 680)

        Window("Network", id: "hoghunter.network") {
            NetworkView { pid in store.lookup(pid: pid) }
        }
        .defaultSize(width: 540, height: 560)
    }
}
