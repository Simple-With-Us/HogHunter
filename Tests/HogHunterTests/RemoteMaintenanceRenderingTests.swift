import AppKit
import SwiftUI
import XCTest

@testable import HogHunter

@MainActor
private final class ScreenshotDisconnectedInfisical: InfisicalServing {
    func login(clientId: String, clientSecret: String) async throws -> String {
        XCTFail("rendering must not authenticate")
        throw InfisicalError.invalidScope
    }
    func fetchSecrets(accessToken: String, environment: String, projectId: String) async throws -> [String: String] {
        XCTFail("rendering must not fetch settings")
        throw InfisicalError.invalidScope
    }
    func upsertSecret(accessToken: String, environment: String, key: String, value: String, projectId: String) async throws {
        XCTFail("rendering must not write settings")
        throw InfisicalError.invalidScope
    }
}

/// The real server maintenance card with a dummy host and scheduling off.
/// Every process/network/settings seam is inert; no action is clicked.
@MainActor
final class RemoteMaintenanceRenderingTests: XCTestCase {
    func testRenderConfiguredServerMaintenanceWithScheduleOff() throws {
        try renderServerMaintenance(filename: "hh207-server-maintenance-schedule-off.png")
    }

    func testRenderServerMaintenanceWithIncompleteInventory() async throws {
        let request = try PendingMaintenanceRequest(host: "maintenance.example.invalid", mode: .scan,
                                                    strategies: ServerMaintenanceStrategy.defaults)
        let object: [String: Any] = [
            "schema_version": 1, "tool": "hoghunter-server-maintenance", "mode": "scan", "manual": true,
            "dry_run": false, "pressure": false, "status": "partial",
            "before": ["free_bytes": 70000, "total_bytes": 100000, "used_percent": 30],
            "after": ["free_bytes": 70000, "total_bytes": 100000, "used_percent": 30],
            "reclaimed_bytes": 0, "observed_free_delta_bytes": 0, "removed_file_bytes": 0,
            "candidate_count": 0, "duration_seconds": 0.1,
            "lock": ["acquired": false], "cancellation": ["requested": false],
            "strategies": request.strategies.map {
                ["id": $0.rawValue, "status": "partial", "inventory_complete": false,
                 "candidate_count": 0, "removed_count": 0, "attempted_count": 0] as [String: Any]
            }
        ]
        let output = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let controller = ServerMaintenanceControl(runner: { host, arguments in
            XCTAssertEqual(host, request.host)
            XCTAssertEqual(arguments, request.arguments)
            return .init(exitCode: 1, output: output)
        })
        await controller.perform(request)
        let result = try XCTUnwrap(controller.result)
        XCTAssertEqual(result.strategies.count, request.strategies.count)
        XCTAssertTrue(result.strategies.allSatisfy { !$0.eligibilityIsKnown(in: result.status) })
        try renderServerMaintenance(control: controller, filename: "hh207-server-maintenance-incomplete-inventory.png")
    }

    private func renderServerMaintenance(control: ServerMaintenanceControl? = nil, filename: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hh207-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"coolify_ssh_host":"maintenance.example.invalid","steps":{"coolify_remote":{"enabled":false}}}"#.utf8)
            .write(to: directory.appendingPathComponent("config.json"))
        let cache = InfisicalStore()
        let infisical = InfisicalSettings(client: ScreenshotDisconnectedInfisical(), store: cache, credentialProvider: { nil })
        let snapshot = try JSONDecoder().decode(VPSStatusSnapshot.self, from: Data(#"{"generated_at":"2026-11-03T12:00:00Z","host":"maintenance.example.invalid","devices":{"root":{"mount":"/","free_bytes":70000000000}},"cpu":{"pct":12,"load1":1,"cores":16},"memory":{"total_bytes":32000000000,"used_bytes":8000000000,"available_bytes":24000000000}}"#.utf8))
        let maintain = MaintainStore(
            supportDirectory: directory, repoRoot: directory,
            launcher: { _ in XCTFail("rendering must not launch maintenance"); return false },
            infisical: infisical, infisicalStore: cache,
            vpsFetcher: { _ in snapshot }
        )
        defer { maintain.vpsStore.stopPolling() }
        XCTAssertEqual(maintain.coolifyHost, "maintenance.example.invalid")
        XCTAssertFalse(maintain.isStepEnabled("coolify_remote"))
        XCTAssertTrue(maintain.stepTogglesPersisted)

        let suite = "hh207-render-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let width = HogHunterPanel.dashboardWidth - 154 - 24 - 36
        let host = NSHostingView(rootView: RemoteMaintenanceCard(maintain: maintain, control: control)
            .padding(12).frame(width: width, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .defaultAppStorage(preferences))
        host.appearance = NSAppearance(named: .aqua)
        XCTAssertLessThanOrEqual(host.fittingSize.width, width + 1)
        let size = CGSize(width: width, height: ceil(host.fittingSize.height))
        XCTAssertGreaterThan(size.height, 100)
        XCTAssertLessThanOrEqual(size.height, 700)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let environment = ProcessInfo.processInfo.environment
        if let folder = environment["HOGHUNTER_RENDER_DIR"] ?? environment["TEST_RUNNER_HOGHUNTER_RENDER_DIR"], !folder.isEmpty {
            let output = URL(fileURLWithPath: folder)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try data.write(to: output.appendingPathComponent(filename))
        }
    }
}
