import SwiftUI

/** CI screenshot hook: launched with `-HogHunterScreenshot`, the app is an accessory whose
 *  initial scene is a `MenuBarExtra`, so nothing visible exists to capture. The delegate opens
 *  the Settings window and orders it front so the capture lane photographs a real app window
 *  instead of the runner desktop. Every step is traced to stderr (the capture script redirects
 *  it to a log and dumps it on failure) so a headless-runner miss shows WHICH layer failed.
 *  Inert without the flag. */
class HogHunterAppDelegate: NSObject, NSApplicationDelegate {
    private var screenshotWindowAttempts = 0

    private func screenshotLog(_ message: String) {
        // FileHandle.standardError.write is unbuffered - each line hits the log immediately.
        FileHandle.standardError.write(Data(("[HogHunterScreenshot] " + message + "\n").utf8))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.arguments.contains("-HogHunterScreenshot") else { return }
        screenshotLog("flag seen; applicationDidFinishLaunching fired (isActive=\(NSApp.isActive))")
        openSettingsForScreenshot()
    }

    private func openSettingsForScreenshot() {
        screenshotWindowAttempts += 1
        // Activate FIRST: an accessory (LSUIElement) app that never activates can open its
        // window behind the previously active app - or, on a headless runner, not at all.
        let activated = NSApp.activate(ignoringOtherApps: true)
        screenshotLog("attempt \(screenshotWindowAttempts): activate(ignoringOtherApps:) -> \(activated)")
        let sent = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        screenshotLog("attempt \(screenshotWindowAttempts): sendAction(showSettingsWindow:) -> \(sent)")
        // Order every visible window front explicitly; activation alone does not guarantee
        // z-order on a runner where Finder owns the screen.
        for window in NSApp.windows where window.isVisible {
            window.makeKeyAndOrderFront(nil)
        }
        let visible = NSApp.windows.filter { $0.isVisible }
        let desc = visible.map { "title=\($0.title.isEmpty ? "<untitled>" : $0.title) size=\(Int($0.frame.width))x\(Int($0.frame.height))" }.joined(separator: "; ")
        screenshotLog("attempt \(screenshotWindowAttempts): \(visible.count) visible window(s) [\(desc)]")
        // The Settings scene can take a moment to materialize on a headless runner. Retry for
        // up to ~15s; if no window exists by then the capture lane fails loudly on its own
        // CGWindowList check instead of photographing the desktop.
        let windowUp = visible.contains { $0.frame.width > 100 && $0.frame.height > 100 }
        if windowUp {
            screenshotLog("window is up after \(screenshotWindowAttempts) attempt(s)")
        } else if screenshotWindowAttempts < 15 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.openSettingsForScreenshot()
            }
        } else {
            screenshotLog("giving up after \(screenshotWindowAttempts) attempts: no >100x100 window ever appeared")
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
