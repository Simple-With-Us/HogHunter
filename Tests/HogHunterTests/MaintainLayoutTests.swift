import AppKit
import SwiftUI
import XCTest

@testable import HogHunter

// The Maintain tab in the menu bar panel.  Issue 117, board d578aa68.
//
// The panel is a fixed 620 by 680.  The Maintain tab was a plain stack taller than the room it was given, so
// the panel's own frame centered the overflow and clipped the top (the panel header and the tab picker went
// out of sight) and the bottom (the last Recent Runs row).  Nothing here launches the real script: the store
// reads files in a temporary folder and takes a launcher that fails the test if it is called.
//
// Set `TEST_RUNNER_HOGHUNTER_RENDER_DIR` to a folder when running `xcodebuild test` to also write PNGs of the
// tab as the panel and the Storage window show it.  With it unset the tests write nothing.

@MainActor
final class MaintainLayoutTests: XCTestCase {

    // MARK: - Sample data

    /// A store holding what a busy week looks like: all nine steps with a result, and 20 cleaning runs among
    /// the five minute checks, with times that differ in width ("6 minutes ago", "1 hour ago", "2 days ago").
    private func sampleStore() throws -> MaintainStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hoghunter-maintain-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let now = Date().timeIntervalSince1970
        func step(_ id: String, _ title: String, _ status: String, _ reason: String, freed: Int = 0) -> MaintainStepResult {
            MaintainStepResult(stepId: id, title: title, status: status, reason: reason, bytesFreed: freed, durationMs: 120)
        }
        let steps = [
            step("resource_sample", "Check disk and memory", "ran", "1 threshold hit"),
            step("hoghunter_reclaim", "Hog Hunter disk reclaim", "ran", "band=cheap: removed 1 of 1 item, 0 B"),
            step("janitor_worktree_retire", "Retire old merged git worktrees", "skipped", "lane doctor unusable: doctor timed out after 300s; nothing removed"),
            step("janitor_cache_reclaim", "Reclaim caches when disk is low", "ran", "band=cheap: removed 0 of 0 items, 0 B"),
            step("pm2_logs", "Cap oversized PM2 logs", "ran", "truncated 0 logs in place"),
            step("npm_cache", "Trim npm download cache", "skipped", "skipped: xcodebuild is running"),
            step("xcode_derived_data", "Clear Xcode build cache", "skipped", "path missing"),
            step("simctl_delete_unavailable", "Remove unavailable Simulator runtimes", "skipped", "not run: it would delete simulator devices in CoreSimulator/Devices, which no cleanup step touches"),
            step("coolify_remote", "Remote server maintenance", "skipped", "coolify_ssh_host not configured"),
        ]
        let status = MaintainStatus(
            health: "healthy",
            launchdLoaded: true,
            nextRunAt: ["full": now + 3 * 3600, "janitor": now + 900],
            intervalsSeconds: ["full": 14_400, "janitor": 900],
            lastRunAt: ["full": now - 1_320],
            lastRun: nil,
            stepLastResults: Dictionary(uniqueKeysWithValues: steps.map { ($0.stepId, $0) }),
            historyCount: 40,
            updatedAt: now
        )
        try JSONEncoder().encode(status).write(to: directory.appendingPathComponent("status.json"))

        // How long ago each of the 20 cleaning runs ended, newest first, with its kind, bytes and outcome.
        let cleaning: [(minutes: Double, kind: String, bytes: Int, outcome: String)] = [
            (6, "janitor", 0, "ok"), (22, "full", 0, "partial"), (37, "janitor", 0, "ok"), (64, "janitor", 0, "ok"),
            (78, "janitor", 15_360, "ok"), (125, "pressure", 0, "ok"), (140, "janitor", 0, "ok"), (155, "janitor", 0, "ok"),
            (185, "janitor", 863_000, "ok"), (200, "janitor", 0, "ok"), (245, "full", 1_288_000_000, "ok"), (260, "janitor", 0, "ok"),
            (440, "manual", 52_428_800, "ok"), (700, "janitor", 0, "ok"), (1_500, "janitor", 4_096, "ok"), (1_560, "full", 0, "failed"),
            (2_900, "janitor", 0, "ok"), (3_000, "pressure", 25_165_824, "ok"), (4_400, "janitor", 0, "ok"), (4_500, "full", 0, "ok"),
        ]
        var runs: [MaintainRun] = cleaning.enumerated().map { index, item in
            let ended = now - item.minutes * 60
            return MaintainRun(
                runId: "c\(index)", trigger: item.kind, startedAt: ended - 40, endedAt: ended, bytesFreed: item.bytes,
                exitCode: item.outcome == "failed" ? 1 : 0,
                steps: [step("pm2_logs", "Cap oversized PM2 logs", "ran", "truncated 0 logs in place")],
                outcome: item.outcome
            )
        }
        // The quiet five minute checks the list leaves out.
        for index in 0..<20 {
            let ended = now - Double(index) * 300 - 30
            runs.append(MaintainRun(
                runId: "w\(index)", trigger: "watch", startedAt: ended - 2, endedAt: ended, bytesFreed: 0, exitCode: 0,
                steps: [step("resource_sample", "Check disk and memory", "ran", "within limits")], outcome: "ok"
            ))
        }
        runs.sort { $0.endedAt < $1.endedAt }   // the engine writes oldest first
        try JSONEncoder().encode(runs).write(to: directory.appendingPathComponent("history.json"))

        return MaintainStore(supportDirectory: directory, repoRoot: directory, launcher: { _ in
            XCTFail("a test must not launch the script")
            return true
        })
    }

    // MARK: - Hosting

    private func storageView(_ store: MaintainStore, embedded: Bool, tab: StorageTab = .maintain) -> StorageView {
        StorageView(runningBundleIds: { [] }, maintainStore: store, embeddedInPanel: embedded, isTabActive: true, initialTab: tab)
    }

    /// The tab as `HogHunterPanel` composes it: pinned to the panel's inner width, clipped, in a `ZStack` under
    /// the panel's own header, inside the fixed panel frame.
    private func panelComposition(_ store: MaintainStore) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Hog Hunter").font(.system(size: 17, weight: .semibold))
                Spacer()
                Picker("Tab", selection: .constant(PanelTab.storage)) {
                    Text("Activity").tag(PanelTab.activity)
                    Text("Storage").tag(PanelTab.storage)
                    Text("Network").tag(PanelTab.network)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 290)
                Spacer()
            }
            .frame(width: HogHunterPanel.contentWidth)
            ZStack(alignment: .topLeading) {
                storageView(store, embedded: true)
                    .frame(width: HogHunterPanel.contentWidth, alignment: .leading)
                    .clipped()
            }
            .frame(width: HogHunterPanel.contentWidth, alignment: .leading)
        }
        .padding(HogHunterPanel.inset)
        .frame(width: HogHunterPanel.panelWidth, height: HogHunterPanel.panelHeight)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Draws the view in an offscreen window the way the screen would, controls included.
    private func bitmap<V: View>(of view: V, size: CGSize) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.contentView = nil
        return rep
    }

    private func savePNG(_ rep: NSBitmapImageRep?, named name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["HOGHUNTER_RENDER_DIR"], !folder.isEmpty else { return }
        let rep = try XCTUnwrap(rep, "nothing rendered for \(name)")
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }

    // MARK: - Tests

    /// **The bug.**  The tab asked for its natural height, which is far more than the panel has, so the panel
    /// frame centered it and clipped both ends.  A tab inside the panel must take the height it is offered and
    /// scroll the rest.  Pinning only the width is what makes this tell the two apart: a fixed-height frame
    /// would report that height whatever the content did.
    func testTheTabTakesTheHeightItIsOfferedAndDoesNotOverflowThePanel() throws {
        let store = try sampleStore()
        let offered: CGFloat = 520   // less than the tab's natural height with nine steps and twenty runs
        let controller = NSHostingController(
            rootView: storageView(store, embedded: true).frame(width: HogHunterPanel.contentWidth, alignment: .leading)
        )
        let fitted = controller.sizeThatFits(in: CGSize(width: HogHunterPanel.contentWidth, height: offered))
        XCTAssertLessThanOrEqual(fitted.height, offered + 1, "the Maintain tab wants \(Int(fitted.height)) pt but was offered \(Int(offered)) pt")
        XCTAssertLessThanOrEqual(fitted.width, HogHunterPanel.contentWidth + 1, "wider than the panel's inner width")
    }

    /// The same holds in the standalone Storage window, which is a resizable window rather than the panel.
    /// It is never shorter than 640 pt, so offer it a little more than that.
    func testTheStandaloneWindowTabAlsoTakesTheHeightItIsOffered() throws {
        let store = try sampleStore()
        let offered: CGFloat = 700
        let controller = NSHostingController(rootView: storageView(store, embedded: false).frame(width: 560, alignment: .leading))
        let fitted = controller.sizeThatFits(in: CGSize(width: 560, height: offered))
        XCTAssertLessThanOrEqual(fitted.height, offered + 1, "the Maintain tab wants \(Int(fitted.height)) pt but was offered \(Int(offered)) pt")
    }

    /// **The header.**  The segmented control (Cleaner, Maintain, Apps) sits in the Storage header next to a
    /// subtitle pinned to its full width.  The Maintain subtitle was long enough that the header was wider than
    /// the panel, so the control lost its "Apps" segment off the right edge and its "Mode" label wrapped
    /// ("Mod" over "e").  Whatever a mode's subtitle says, the view's own width must fit the panel.
    func testEveryModeFitsThePanelWidth() throws {
        let store = try sampleStore()
        for tab in StorageTab.allCases {
            let host = NSHostingView(rootView: storageView(store, embedded: true, tab: tab))
            XCTAssertLessThanOrEqual(host.fittingSize.width, HogHunterPanel.contentWidth + 1, "\(tab.rawValue) is wider than the panel")
        }
    }

    /// Draws the panel and the window.  The assertions are only that something was drawn at the right size;
    /// the PNGs (when asked for) are what a person looks at.
    func testRenderThePanelAndTheStandaloneWindow() throws {
        let store = try sampleStore()
        let panelSize = CGSize(width: HogHunterPanel.panelWidth, height: HogHunterPanel.panelHeight)
        let panel = bitmap(of: panelComposition(store), size: panelSize)
        XCTAssertEqual(panel?.pixelsWide, Int(panelSize.width * (panel.map { CGFloat($0.pixelsWide) / panelSize.width } ?? 1)))
        try savePNG(panel, named: "maintain-panel")

        // The whole tab on one picture, tall enough that nothing scrolls out of sight: every Recent Runs row.
        let tall = CGSize(width: HogHunterPanel.contentWidth, height: 1_100)
        let all = bitmap(of: MaintainView(store: store).frame(width: tall.width, height: tall.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)), size: tall)
        XCTAssertNotNil(all)
        try savePNG(all, named: "maintain-tab-all-rows")

        let windowSize = CGSize(width: 560, height: 680)
        let window = bitmap(of: storageView(store, embedded: false).frame(width: windowSize.width, height: windowSize.height)
            .background(Color(nsColor: .windowBackgroundColor)), size: windowSize)
        XCTAssertNotNil(window)
        try savePNG(window, named: "maintain-window")
    }
}
