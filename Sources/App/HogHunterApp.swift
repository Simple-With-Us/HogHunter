import SwiftUI

/** CI screenshot hook: launched with `-HogHunterScreenshot`, the app is an accessory whose
 *  initial scene is a `MenuBarExtra`, so nothing visible exists to capture. The delegate opens
 *  an NSWindow hosting SettingsView and orders it front so the capture lane photographs a real
 *  app window instead of the runner desktop. Every step is traced to stderr so a headless-runner
 *  miss shows WHICH layer failed. Inert without the flag. */
class HogHunterAppDelegate: NSObject, NSApplicationDelegate {
    private var screenshotWindow: NSWindow?

    /// One app, one menu bar item, one set of timers.
    ///
    /// Without this a second launch starts a second Hog Hunter.  That is not
    /// cosmetic: macOS grants Full Disk Access per binary *and* pid, so two
    /// copies probe protected paths independently and the owner gets the same
    /// permission prompt twice, with denying one leaving the other asking.
    ///
    /// Checked in `willFinishLaunching`, before any window or timer exists, so
    /// the loser never gets far enough to own anything.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let isRunningTests = NSClassFromString("XCTestCase") != nil
        let handOver = SingleInstance.shouldHandOver(
            argumentStrings: ProcessInfo.processInfo.arguments,
            isRunningTests: isRunningTests,
            ownPID: ProcessInfo.processInfo.processIdentifier,
            runningPIDs: RunningCopies.otherPIDs(
                bundleIdentifier: Bundle.main.bundleIdentifier,
                ownPID: ProcessInfo.processInfo.processIdentifier
            )
        )
        guard handOver else { return }
        // Bring the incumbent forward so the owner's click appears to do
        // something, then step aside.
        if let bundleID = Bundle.main.bundleIdentifier {
            for other in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            where other.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                other.activate(options: [.activateAllWindows])
            }
        }
        NSApp.terminate(nil)
    }

    private func screenshotLog(_ message: String) {
        // FileHandle.standardError.write is unbuffered - each line hits the log immediately.
        FileHandle.standardError.write(Data(("[HogHunterScreenshot] " + message + "\n").utf8))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Headless UI smoke test.  Runs before anything else touches the app so
        // it is not racing the sampler, the bandwidth timer, or the screenshot
        // hook.  See UISmokeTest for why this exists.
        if ProcessInfo.processInfo.arguments.contains(HarnessArgument.uiSmoke) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { UISmokeTest.run() }
            return
        }
        guard ProcessInfo.processInfo.arguments.contains(HarnessArgument.screenshot) else { return }
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

    init() {
        // Infisical SOT bootstrap: fetches app-level settings into the
        // in-memory cache on a background task.  Never blocks launch; when
        // Infisical is not configured (or unreachable) every built-in default
        // and UserDefaults value stands exactly as before.  See INFISICAL.md.
        Task { @MainActor in await InfisicalSettings.shared.bootstrap() }
    }

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

        // Storage and Network are tabs of the menu bar panel.  These scenes stay
        // for the Window menu's benefit; nothing in the UI points at them.
        Window("Storage", id: "hoghunter.storage") {
            StorageView(runningBundleIds: { store.runningBundleIdsSnapshot() }, maintainStore: store.maintain)
        }
        .defaultSize(width: 560, height: 680)

        Window("Network", id: "hoghunter.network") {
            NetworkView(
                bundleResolver: { pid in store.lookup(pid: pid) },
                bandwidth: store.bandwidth
            )
            .environmentObject(store)
        }
        .defaultSize(width: 540, height: 560)
    }
}
