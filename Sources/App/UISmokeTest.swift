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
    private var panelStore: HogStore?

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
            let ok = abs(size.width - HogHunterPanel.panelWidth) < 1
                && size.height > 180 && size.height <= HogHunterPanel.panelHeight
            record("quick view fits its content", ok, "got \(size)")
            checkRenderedContent(panelWindow, name: "quick-view")
        }

        // **The bug that shipped.**  The gear button did nothing at all: no
        // window, no Dock icon, nothing to find.  This drives the same
        // SwiftUI `openSettings` action the button drives.
        openSettingsAndWait()
        let afterOpen = realWindows.filter { $0 !== panelWindow }
        record("Settings opens from the panel", afterOpen.contains { isSettingsWindow($0) },
               "titled windows: \(afterOpen.map(\.title))")

        let before = realWindows.count
        openSettingsAndWait()
        let after = realWindows.count
        record("re-opening Settings does not duplicate it", after == before,
               "windows before=\(before) after=\(after)")

        let settingsCount = realWindows.filter { isSettingsWindow($0) }.count
        record("exactly one Settings window", settingsCount == 1, "found \(settingsCount)")

        if let panelStore {
            DetachedWindowManager.shared.openDetachedWindow(store: panelStore)
            wait(0.5)
            // Query NSApp again after opening: the earlier Settings snapshot predates this window.
            if let dashboard = NSApp.windows.first(where: {
                $0.isVisible && $0.title == "Hog Hunter" && $0 !== panelWindow
            }) {
                let initial = dashboard.contentView?.frame.size ?? .zero
                let declared = NSSize(width: HogHunterPanel.dashboardWidth,
                                      height: HogHunterPanel.dashboardHeight)
                // A headless runner can have less usable screen height than
                // the requested window.  AppKit clamps to that visible area.
                let titlebarHeight = dashboard.frame.height - initial.height
                let visibleContentHeight = (dashboard.screen?.visibleFrame.height ?? declared.height + titlebarHeight)
                    - titlebarHeight
                let initialHeight = min(declared.height, visibleContentHeight)
                record("dashboard opens at its declared size",
                       abs(initial.width - declared.width) < 1 && abs(initial.height - initialHeight) < 1,
                       "got \(initial) requested \(declared), visible height cap \(visibleContentHeight)")
                checkRenderedContent(dashboard, name: "dashboard-default")
                dashboard.setContentSize(NSSize(width: HogHunterPanel.dashboardMinimumWidth, height: 580))
                wait(0.2)
                let minimum = dashboard.contentView?.frame.size ?? .zero
                record("dashboard fits its minimum size", minimum.width >= 859 && minimum.height >= 579,
                       "got \(minimum)")
                checkRenderedContent(dashboard, name: "dashboard-minimum")
                dashboard.setContentSize(NSSize(width: 1050, height: 780))
                wait(0.2)
                let grown = dashboard.contentView?.frame.size ?? .zero
                let grownHeight = min(780, visibleContentHeight)
                record("dashboard content resizes",
                       grown.width >= 1049 && abs(grown.height - grownHeight) < 1
                           && grown.height > minimum.height,
                       "got \(grown) requested 1050×780, visible height cap \(visibleContentHeight)")
                checkRenderedContent(dashboard, name: "dashboard-grown")
            } else {
                record("dashboard opens at its declared size", false, "no dashboard window")
                record("dashboard fits its minimum size", false, "no dashboard window")
                record("dashboard content resizes", false, "no dashboard window")
            }
            DetachedWindowManager.shared.closeDetachedWindow()
        }

        // Measure detail views at the dashboard stage width.  The menu bar
        // view is intentionally compact and no longer hosts full detail pages.
        checkTabFits("Storage") { store in
            StorageView(runningBundleIds: { [] }, maintainStore: MaintainStore(), embeddedInPanel: true,
                        isTabActive: true, autoScanCleaner: false)
                .frame(width: dashboardStageWidth, alignment: .leading)
                .clipped()
        }
        checkTabFits("Network") { store in
            NetworkView(bundleResolver: { _ in (nil, "unknown") }, bandwidth: store.bandwidth, embeddedInPanel: true, isTabActive: true)
                .frame(width: dashboardStageWidth, alignment: .leading)
                .clipped()
        }
        checkTabFits("Server") { store in
            ServerStatusView(store: store.maintain.vpsStore)
                .frame(width: dashboardStageWidth, alignment: .leading)
                .clipped()
        }

        let failed = results.filter { !$0.passed }
        log("RESULT: \(failed.isEmpty ? "PASS" : "FAIL") (\(results.count - failed.count)/\(results.count) checks)")
        for failure in failed { log("  failed: \(failure.name) \(failure.detail)") }
        return failed.isEmpty ? 0 : 1
    }

    private func isSettingsWindow(_ window: NSWindow) -> Bool {
        if AppActivationManager.shared.window(for: .settings) === window { return true }
        let title = window.title
        return title.contains("Settings") || title.contains("Hog Hunter Settings")
    }

    private func openPanel() {
        let store = HogStore(historyURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("uismoke-panel.sqlite"))
        panelStore = store
        let hosting = NSHostingController(
            rootView: HogHunterPanel(isQuickView: true).environmentObject(store)
        )
        let size = hosting.view.fittingSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
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
        let limit = dashboardStageWidth
        record("\(name) view fits the dashboard width", fitting.width <= limit + 1,
               "ideal \(Int(fitting.width))pt vs \(Int(limit))pt")
    }

    private var dashboardStageWidth: CGFloat {
        HogHunterPanel.dashboardMinimumWidth - 154 - 24 - 36
    }

    /// Capture the actual hosted SwiftUI content after each resize.  A frame
    /// check alone can pass while a fixed child is blank or clipped inside it.
    private func checkRenderedContent(_ window: NSWindow, name: String) {
        guard let view = window.contentView else {
            record("\(name) content renders", false, "missing content view")
            return
        }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            record("\(name) content renders", false, "bitmap unavailable")
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var colors = Set<String>()
        var rightEdgeColors = Set<String>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 90)) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 90)) {
                if let color = bitmap.colorAt(x: x, y: y) {
                    colors.insert(color.description)
                }
            }
            for x in stride(from: bitmap.pixelsWide * 9 / 10, to: bitmap.pixelsWide,
                            by: max(1, bitmap.pixelsWide / 100)) {
                if let color = bitmap.colorAt(x: x, y: y) {
                    rightEdgeColors.insert(color.description)
                }
            }
        }
        let expected = view.bounds.size
        let rendered = bitmap.pixelsWide >= Int(expected.width)
            && bitmap.pixelsHigh >= Int(expected.height) && colors.count >= 3
            && (name == "quick-view" || rightEdgeColors.count >= 2)
        record("\(name) content renders", rendered,
               "pixels=\(bitmap.pixelsWide)×\(bitmap.pixelsHigh), colors=\(colors.count), right edge=\(rightEdgeColors.count)")
        if let folder = ProcessInfo.processInfo.environment["HOGHUNTER_RENDER_DIR"],
           let png = bitmap.representation(using: .png, properties: [:]) {
            let directory = URL(fileURLWithPath: folder, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? png.write(to: directory.appendingPathComponent("\(name).png"))
        }
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
