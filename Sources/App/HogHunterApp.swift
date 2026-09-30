import SwiftUI

@main
struct HogHunterApp: App {
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
