import AppKit
import SwiftUI

/// Headless UI smoke test.  Launched with `-HogHunterUISmoke`, it drives the
/// real SwiftUI views and the real `NSApp` window list on a machine with no
/// one logged in, prints one `UITEST <name>: PASS|FAIL` line per check and a
/// final `UITEST RESULT:`, then exits with a status code.
///
/// This exists because defects shipped through a fully green build and a
/// passing test suite: Settings would not open at all, and the Network tab's
/// content was 155 pt wider than the panel that holds it, so switching tabs
/// briefly blew the window out of its own bounds.  Neither is visible to a
/// unit test.  Both are trivially visible to "launch the app, poke it, look at
/// the window list" -- so CI does exactly that on the macOS runner instead of
/// a human doing it at 2am.
///
/// Assertions deliberately do NOT consult `AppActivationManager`'s own role
/// registry.  If registration is what broke, asking it where the window is
/// would return nil for both the app and the test and the test would pass.
@MainActor
final class UISmokeTest {

    private var results: [(name: String, passed: Bool, detail: String)] = []
    private var panelWindow: NSWindow?

    static func run() -> Never {
        let test = UISmokeTest()
        let status = test.execute()
        exit(status)
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data(("[UISmoke] " + message + "\n").utf8))
    }

    private func record(_ name: String, _ passed: Bool, _ detail: String = "") {
        results.append((name, passed, detail))
        log("\(name): \(passed ? "PASS" : "FAIL")\(detail.isEmpty ? "" : " — " + detail)")
    }

    /// Every visible titled window that is not the menu bar panel: the
    /// population a user would actually find on screen.
    private var realWindows: [NSWindow] {
        NSApp.windows.filter { window in
            window.isVisible && window.styleMask.contains(.titled) && !(window is NSPanel)
        }
    }

    private func wait(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func execute() -> Int32 {
        log("starting; NSApp.isActive=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue)")

        openPanel()
        record("panel window opens", panelWindow != nil,
               panelWindow.map { "content=\($0.contentView?.frame.size ?? .zero)" } ?? "no window")

        if let panelWindow {
            // contentView, not the window: the window frame includes the title bar.
            let size = panelWindow.contentView?.frame.size ?? .zero
            let expected = NSSize(width: HogHunterPanel.panelWidth, height: HogHunterPanel.panelHeight)
            let ok = abs(size.width - expected.width) < 1 && abs(size.height - expected.height) < 1
            record("panel window is its declared size", ok, "got \(size) want \(expected)")
        }

        // **The bug that shipped.**  The gear button did nothing at all: no
        // window, no Dock icon, nothing to find.  This drives the same
        // SwiftUI `openSettings` action the button drives.
        openSettingsAndWait()
        let afterOpen = realWindows.filter { $0 !== panelWindow }
        record("Settings opens from the panel", afterOpen.contains { isSettingsWindow($0) },
               "titled windows: \(afterOpen.map { "\($0.title ?? "<untitled>")" })")

        let before = realWindows.count
        openSettingsAndWait()
        let after = realWindows.count
        record("re-opening Settings does not duplicate it", after == before,
               "windows before=\(before) after=\(after)")

        let settingsCount = realWindows.filter { isSettingsWindow($0) }.count
        record("exactly one Settings window", settingsCount == 1, "found \(settingsCount)")

        // Measured the way HogHunterPanel composes it -- pinned to the panel
        // width and clipped.  Measuring the bare view would report the content's
        // own appetite for width, which is not what ships and would make this
        // test fail forever.
        checkTabFits("Storage") { store in
            StorageView(runningBundleIds: { [] }, vacuumStore: RoboticVacuumStore(), embeddedInPanel: true, isTabActive: true)
                .frame(width: HogHunterPanel.contentWidth, alignment: .leading)
                .clipped()
        }
        checkTabFits("Network") { store in
            NetworkView(bundleResolver: { _ in (nil, "unknown") }, bandwidth: store.bandwidth, embeddedInPanel: true, isTabActive: true)
                .frame(width: HogHunterPanel.contentWidth, alignment: .leading)
                .clipped()
        }

        let failed = results.filter { !$0.passed }
        log("RESULT: \(failed.isEmpty ? "PASS" : "FAIL") (\(results.count - failed.count)/\(results.count) checks)")
        for failure in failed { log("  failed: \(failure.name) \(failure.detail)") }
        return failed.isEmpty ? 0 : 1
    }

    private func isSettingsWindow(_ window: NSWindow) -> Bool {
        if AppActivationManager.shared.window(for: .settings) === window { return true }
        let title = window.title ?? ""
        return title.contains("Settings") || title.contains("Hog Hunter Settings")
    }

    private func openPanel() {
        let store = HogStore(historyURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("uismoke-panel.sqlite"))
        let size = NSSize(width: HogHunterPanel.panelWidth, height: HogHunterPanel.panelHeight)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = NSHostingController(
            rootView: HogHunterPanel().environmentObject(store).frame(width: size.width, height: size.height)
        )
        window.contentMinSize = size
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        AppActivationManager.shared.registerWindow(window)
        panelWindow = window
        wait(1.0)
    }

    /// Fires the *same* SwiftUI `openSettings` environment action the gear
    /// button fires, by hosting a view that calls it on appear.  Anything less
    /// (a hand-rolled `sendAction`, a direct call into `HogActions`) would let
    /// this test go green while the button stayed dead, which is exactly the
    /// failure it exists to prevent.
    private func openSettingsAndWait() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = NSHostingController(rootView: SettingsOpenerProbe())
        window.orderFront(nil)
        wait(0.5)
        HogActions.scheduleFrontSettingsWindow()
        wait(0.9)
        window.orderOut(nil)
    }

    /// A tab whose content wants more width than the panel has will be laid out
    /// at that width before the panel's own frame is applied, which is the
    /// shape of the "window is oversized and cropped for a few seconds" report.
    private func checkTabFits<Content: View>(_ name: String,
                                            _ view: (HogStore) -> Content) {
        let store = HogStore(historyURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("uismoke-\(name).sqlite"))
        let hosting = NSHostingView(rootView: view(store))
        let fitting = hosting.fittingSize
        let limit = HogHunterPanel.contentWidth
        record("\(name) tab fits the panel width", fitting.width <= limit + 1,
               "ideal \(Int(fitting.width))pt vs \(Int(limit))pt")
    }
}

/// Calls SwiftUI's `openSettings` on appear.  Deliberately a separate view so
/// the environment action is read from a real view hierarchy, exactly as the
/// gear button reads it.
private struct SettingsOpenerProbe: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .onAppear {
                if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
                openSettings()
            }
    }
}
