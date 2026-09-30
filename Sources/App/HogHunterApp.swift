import SwiftUI

/** CI screenshot hook: launched with `-HogHunterScreenshot`, the app is an accessory whose
 *  initial scene is a `MenuBarExtra`, so nothing visible exists to capture. The delegate opens
 *  the Settings window shortly after launch so the capture lane photographs a real app window
 *  instead of the runner desktop. Inert without the flag. */
class HogHunterAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.arguments.contains("-HogHunterScreenshot") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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
