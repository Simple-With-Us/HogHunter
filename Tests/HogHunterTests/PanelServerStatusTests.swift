import AppKit
import SwiftUI
import XCTest

@testable import HogHunter

/// The panel's server status.  Owner 2026-10-19: the server readings used to
/// live inside the Maintain tab, where the card buried the maintenance content
/// and the readings sat below the fold, so nobody knew they were there.
///
/// These tests pin the three things that could quietly break again: the panel
/// has a Server tab, the strip fits the panel it sits in, and the readings
/// reach the panel without a view having to be open somewhere else first.
@MainActor
final class PanelServerStatusTests: XCTestCase {

    private func sampleSnapshot() throws -> VPSStatusSnapshot {
        let json = """
        {
          "generated_at": "2026-10-18T19:15:03Z",
          "host": "fleet-hetzner-nbg1",
          "devices": {"root": {"mount": "/", "free_bytes": 74097487872, "note": "301GB disk: OS"}},
          "cpu": {"pct": 24.8, "load1": 3.07, "cores": 16},
          "memory": {"total_bytes": 32853925888, "used_bytes": 9095159808, "available_bytes": 23758766080}
        }
        """.data(using: .utf8)!
        return try JSONDecoder().decode(VPSStatusSnapshot.self, from: json)
    }

    /// A store whose server readings are already in hand, so nothing is
    /// fetched: the SSH fetcher refuses to run under a test.
    private func store(withSnapshot snapshot: VPSStatusSnapshot?) -> MaintainStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hoghunter-panel-server-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return MaintainStore(
            supportDirectory: directory,
            repoRoot: directory,
            launcher: { _ in
                XCTFail("a test must not launch the script")
                return true
            },
            vpsFetcher: { _ in
                guard let snapshot else {
                    throw NSError(domain: "test", code: 1, userInfo: nil)
                }
                return snapshot
            }
        )
    }

    // MARK: - The tab

    /// The server readings are on the main window now, so the panel has a tab
    /// for them.  A tab that only exists in a corner nobody opens is how they
    /// were lost in the first place.
    func testThePanelHasAServerTab() {
        XCTAssertTrue(PanelTab.allCases.contains(.server))
        XCTAssertEqual(PanelTab.server.rawValue, "Server")
    }

    /// The tab picker holds four labels now, so it has to be wide enough for
    /// them.  A segmented picker that is too narrow drops its last segment off
    /// the right edge, which is how the Storage tab once lost "Apps".
    func testTheTabPickerFitsThePanelWidth() {
        let header = HStack(spacing: 8) {
            Text("Hog Hunter").font(.system(size: 17, weight: .semibold))
            Spacer()
            Picker("Tab", selection: .constant(PanelTab.server)) {
                Label("Activity", image: "HogProfile").tag(PanelTab.activity)
                Label("Storage", systemImage: "internaldrive").tag(PanelTab.storage)
                Label("Network", systemImage: "network").tag(PanelTab.network)
                Label("Server", systemImage: "server.rack").tag(PanelTab.server)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 360)
            Spacer()
        }
        .frame(width: HogHunterPanel.contentWidth)

        let host = NSHostingView(rootView: header)
        XCTAssertLessThanOrEqual(host.fittingSize.width, HogHunterPanel.contentWidth + 1)
    }

    // MARK: - The strip

    /// The strip sits on the Activity tab, so it has to fit the panel's inner
    /// width without pushing the list off the edge.
    func testTheServerStripFitsThePanelWidth() throws {
        let snapshot = try sampleSnapshot()
        let maintain = store(withSnapshot: snapshot)
        maintain.vpsStore.setHost("fleet-hetzner-nbg1")

        let host = NSHostingView(
            rootView: VPSStatusStripView(store: maintain.vpsStore, onOpen: {})
                .frame(width: HogHunterPanel.contentWidth, alignment: .leading)
        )
        XCTAssertLessThanOrEqual(host.fittingSize.width, HogHunterPanel.contentWidth + 1)
    }

    /// The strip is a button, and what it says is spoken: a person using a
    /// screen reader hears the server's state without reading a row of
    /// percentages off the screen.
    func testTheStripNamesTheHostAndItsReadings() throws {
        let snapshot = try sampleSnapshot()
        let label = VPSStatusStripView.stripLabel(snapshot: snapshot)
        XCTAssertTrue(label.contains("fleet-hetzner-nbg1"), label)
        XCTAssertTrue(label.contains("25%"), label)
        XCTAssertTrue(label.contains("28%"), label)
        XCTAssertTrue(label.contains("77% used"), label)
    }

    /// With nothing to report the label says so, rather than naming a host
    /// that is not there.
    func testTheStripLabelWithoutASnapshot() {
        XCTAssertEqual(VPSStatusStripView.stripLabel(snapshot: nil), "Remote server status")
    }

    // MARK: - What it looks like

    /// Draws the panel with a server to look at.  Set `HOGHUNTER_RENDER_DIR`
    /// to a folder, or create `/tmp/hoghunter-render`, and the pictures land
    /// there; without either the test draws nothing and only checks that
    /// something was drawn.
    func testRenderThePanelWithAServer() async throws {
        let snapshot = try sampleSnapshot()
        let maintain = store(withSnapshot: snapshot)
        maintain.vpsStore.setHost("fleet-hetzner-nbg1")
        maintain.vpsStore.fetch(force: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNotNil(maintain.vpsStore.snapshot, "the stub fetcher must have answered")

        let size = CGSize(width: HogHunterPanel.panelWidth, height: HogHunterPanel.panelHeight)
        let panel = bitmap(of: VPSStatusStripView(store: maintain.vpsStore, onOpen: {})
            .frame(width: size.width - 28, height: 40, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: size.width, height: 40))
        XCTAssertNotNil(panel)
        try savePNG(panel, named: "server-strip")

        let tab = bitmap(of: ServerStatusView(store: maintain.vpsStore)
            .frame(width: size.width - 28, height: 520, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: size.width - 28, height: 520))
        XCTAssertNotNil(tab)
        try savePNG(tab, named: "server-tab")

        // The whole panel, as the menu bar shows it, with the strip in place.
        let hogStore = HogStore(
            historyURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("panel-server-\(UUID().uuidString).sqlite"),
            maintain: maintain
        )
        let wholePanel = bitmap(of: HogHunterPanel().environmentObject(hogStore)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)), size: size)
        XCTAssertNotNil(wholePanel)
        try savePNG(wholePanel, named: "panel-with-server-strip")
    }

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
        guard let folder = Self.renderFolder else { return }
        let rep = try XCTUnwrap(rep, "nothing rendered for \(name)")
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }

    /// Where the pictures land.  The environment variable is the way the
    /// existing render tests take it, but it does not always reach the test
    /// host, so an existing directory asks for the pictures too.
    private static var renderFolder: String? {
        if let folder = ProcessInfo.processInfo.environment["HOGHUNTER_RENDER_DIR"], !folder.isEmpty {
            return folder
        }
        let folder = "/tmp/hoghunter-render"
        return FileManager.default.fileExists(atPath: folder) ? folder : nil
    }
}
