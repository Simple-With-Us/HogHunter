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
            win.contentViewController = NSHostingController(rootView: SettingsView().environmentObject(store))
            win.center()
            AppActivationManager.shared.windowOpened()
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.screenshotWindow = win
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
            HStack(spacing: 3) {
                Image(systemName: "flame.fill")
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
