import XCTest
import Darwin
@testable import HogHunter

@MainActor
final class ServerMaintenanceControlTests: XCTestCase {
    func testRequestFreezesHostModeAndChoicesWithFixedArguments() throws {
        var host = "server.example"
        var choices = ServerMaintenanceStrategy.defaults
        let request = try PendingMaintenanceRequest(host: host, mode: .run, strategies: choices)
        host = "other.example"
        choices = [.images]
        XCTAssertEqual(request.host, "server.example")
        XCTAssertEqual(request.strategies, ServerMaintenanceStrategy.defaults)
        XCTAssertFalse(request.includesImages)
        XCTAssertEqual(request.arguments, ["sudo", "-n", "/usr/local/sbin/hoghunter-maintain", "run", "--manual",
            "--strategy", "package-cache", "--strategy", "rotated-logs", "--strategy", "docker-build-cache", "--confirm"])
    }

    func testInvalidHostsAndSelectorsCannotReachTransport() {
        for host in ["", "-oProxyCommand=x", "host name", "server;other", "server\nother", "server$(other)"] {
            XCTAssertThrowsError(try PendingMaintenanceRequest(host: host, mode: .scan, strategies: [.packageCache]))
        }
        XCTAssertThrowsError(try PendingMaintenanceRequest(host: "server", mode: .run, strategies: []))
        XCTAssertThrowsError(try PendingMaintenanceRequest(host: "server", mode: .scan, strategies: [.images, .images]))
        XCTAssertNoThrow(try PendingMaintenanceRequest(host: "jay@[::1]", mode: .scan, strategies: [.buildCache]))
    }

    func testManualScanNeedsNoConfirmationOrScheduleOptIn() async throws {
        let request = try PendingMaintenanceRequest(host: "server", mode: .scan, strategies: [.packageCache])
        let recorded = MaintenanceCommandRecorder()
        let output = try fixture(mode: "scan", status: "planned")
        let control = ServerMaintenanceControl(runner: { host, args in
            await recorded.record(host: host, args: args)
            return .init(exitCode: 0, output: output)
        })
        await control.perform(request)
        let arguments = await recorded.arguments
        XCTAssertEqual(arguments, ["sudo", "-n", "/usr/local/sbin/hoghunter-maintain", "scan", "--manual", "--strategy", "package-cache"])
        XCTAssertEqual(control.result?.candidateCount, 1)
        XCTAssertEqual(control.result?.removedFileBytes, 0)
    }

    func testRunAndImagesRequireDistinctExplicitConfirmation() async throws {
        let recorded = MaintenanceCommandRecorder()
        let output = try fixture(mode: "run", status: "ran", strategy: "docker-images")
        let control = ServerMaintenanceControl(runner: { host, args in
            await recorded.record(host: host, args: args)
            return .init(exitCode: 0, output: output)
        })
        let request = try PendingMaintenanceRequest(host: "server", mode: .run, strategies: [.images])
        await control.perform(request)
        await control.perform(request, confirmed: true)
        let before = await recorded.count
        XCTAssertEqual(before, 0)
        await control.perform(request, confirmed: true, imageRemovalConfirmed: true)
        let after = await recorded.count
        XCTAssertEqual(after, 1)
        XCTAssertEqual(control.result?.status, "ran")
    }

    func testStructuredRunKeepsLogicalRemovalAndSignedSpaceDeltaSeparate() throws {
        let request = try PendingMaintenanceRequest(host: "server", mode: .run, strategies: [.packageCache])
        let result = try ServerMaintenanceResult.parse(.init(exitCode: 0, output: fixture(mode: "run", status: "ran")), for: request)
        XCTAssertEqual(result.removedFileBytes, 8192)
        XCTAssertEqual(result.observedFreeDeltaBytes, -4096)
        XCTAssertEqual(result.reclaimedBytes, 0)
        XCTAssertTrue(result.lock.acquired)
    }

    func testMalformedMismatchedOrUnserializedResultsAreRefused() throws {
        let request = try PendingMaintenanceRequest(host: "server", mode: .scan, strategies: [.packageCache])
        let valid = try fixture(mode: "scan", status: "planned")
        for (field, value) in [("schema_version", true as Any), ("mode", "run"), ("manual", false),
                               ("dry_run", true), ("candidate_count", -1), ("candidate_count", 99),
                               ("duration_seconds", -1), ("status", "ran"), ("removed_file_bytes", 1),
                               ("observed_free_delta_bytes", 999)] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(valid.utf8)) as? [String: Any])
            object[field] = value
            let output = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            XCTAssertThrowsError(try ServerMaintenanceResult.parse(.init(exitCode: 0, output: output), for: request), field)
        }
        for output in ["", "not JSON", valid + " trailing", String(repeating: "x", count: 1_048_577),
                       try fixture(mode: "scan", status: "planned", strategy: "docker-images")] {
            XCTAssertThrowsError(try ServerMaintenanceResult.parse(.init(exitCode: 0, output: output), for: request))
        }
        XCTAssertThrowsError(try ServerMaintenanceResult.parse(.init(exitCode: 255, output: valid), for: request))
        let allSelected = try PendingMaintenanceRequest(host: "server", mode: .scan, strategies: ServerMaintenanceStrategy.defaults)
        XCTAssertThrowsError(try ServerMaintenanceResult.parse(.init(exitCode: 0, output: valid), for: allSelected),
                             "A complete response must cover every frozen selected strategy")
        let run = try PendingMaintenanceRequest(host: "server", mode: .run, strategies: [.packageCache])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fixture(mode: "run", status: "ran").utf8)) as? [String: Any])
        object["lock"] = ["acquired": false]
        let output = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        XCTAssertThrowsError(try ServerMaintenanceResult.parse(.init(exitCode: 0, output: output), for: run))
    }

    func testConcurrentRequestIsRefusedWhileFirstTransportWaits() async throws {
        let gate = MaintenanceGate()
        let request = try PendingMaintenanceRequest(host: "server", mode: .scan, strategies: [.packageCache])
        let output = try fixture(mode: "scan", status: "planned")
        let control = ServerMaintenanceControl(runner: { _, _ in
            await gate.wait()
            return .init(exitCode: 0, output: output)
        })
        let first = Task { await control.perform(request) }
        while !control.isWorking { await Task.yield() }
        await control.perform(request)
        XCTAssertEqual(control.message, "Another server maintenance request is already running.")
        await gate.release()
        await first.value
        let count = await gate.count
        XCTAssertEqual(count, 1)
    }

    func testEveryTerminalErrorRequiresAllFrozenSelectedStrategies() throws {
        for mode in [PendingMaintenanceRequest.Mode.scan, .run] {
            let request = try PendingMaintenanceRequest(host: "server", mode: mode, strategies: ServerMaintenanceStrategy.defaults)
            for status in ["partial", "failed", "cancelled"] {
                var object = try object(mode: mode.rawValue, status: "partial")
                object["status"] = status
                object["cancellation"] = ["requested": status == "cancelled"]
                XCTAssertThrowsError(try ServerMaintenanceResult.parse(.init(exitCode: 1, output: encoded(object)), for: request),
                                     "Matching totals cannot excuse an omitted selected strategy: \(status)")
                object["strategies"] = []
                object["candidate_count"] = 0
                XCTAssertThrowsError(try ServerMaintenanceResult.parse(.init(exitCode: 1, output: encoded(object)), for: request))
                object["strategies"] = request.strategies.map {
                    ["id": $0.rawValue, "status": "partial", "inventory_complete": false,
                     "candidate_count": 0, "removed_count": 0, "attempted_count": 0] as [String: Any]
                }
                let result = try ServerMaintenanceResult.parse(.init(exitCode: 1, output: encoded(object)), for: request)
                XCTAssertEqual(Set(result.strategies.map(\.id)), Set(request.strategies.map(\.rawValue)))
                XCTAssertTrue(result.strategies.allSatisfy { !$0.eligibilityIsKnown(in: result.status) })
            }
        }
    }

    func testEmptyStrategyExceptionRequiresTheExactUnacquiredBusyContract() throws {
        let request = try PendingMaintenanceRequest(host: "server", mode: .run, strategies: ServerMaintenanceStrategy.defaults)
        var busy = try object(mode: "run", status: "skipped")
        busy["reason"] = "shared remote cleanup lock busy; no work started"
        busy["strategies"] = []
        busy["candidate_count"] = 0
        let result = try ServerMaintenanceResult.parse(.init(exitCode: 0, output: encoded(busy)), for: request)
        XCTAssertTrue(result.strategies.isEmpty)
        XCTAssertEqual(result.message, "Server cleanup is busy; no work started.")
        for (field, value) in [("reason", "no eligible work" as Any), ("reason", NSNull()),
                               ("lock", ["acquired": true]), ("lock", ["acquired": false, "released": true]),
                               ("lock", ["acquired": false, "released": false]),
                               ("cancellation", ["requested": true]), ("removed_file_bytes", 1), ("manual", false)] {
            var malformed = busy
            malformed[field] = value
            XCTAssertThrowsError(try ServerMaintenanceResult.parse(.init(exitCode: 0, output: encoded(malformed)), for: request), field)
        }
        let scan = try PendingMaintenanceRequest(host: "server", mode: .scan, strategies: request.strategies)
        busy["mode"] = "scan"
        XCTAssertThrowsError(try ServerMaintenanceResult.parse(.init(exitCode: 0, output: encoded(busy)), for: scan))
    }

    func testInventoryCompletenessIsTypedAndCannotHideActionsOrClaimUnscannedZeroEligibility() throws {
        let request = try PendingMaintenanceRequest(host: "server", mode: .scan, strategies: [.packageCache])
        for invalid in ["true" as Any, 1, 0, [true]] {
            var malformed = try object(mode: "scan", status: "planned")
            var rows = try XCTUnwrap(malformed["strategies"] as? [[String: Any]])
            rows[0]["inventory_complete"] = invalid
            malformed["strategies"] = rows
            XCTAssertThrowsError(try ServerMaintenanceResult.parse(.init(exitCode: 0, output: encoded(malformed)), for: request))
        }
        var inconsistent = try object(mode: "scan", status: "planned")
        var rows = try XCTUnwrap(inconsistent["strategies"] as? [[String: Any]])
        rows[0]["inventory_complete"] = false
        inconsistent["strategies"] = rows
        XCTAssertThrowsError(try ServerMaintenanceResult.parse(.init(exitCode: 0, output: encoded(inconsistent)), for: request))
        let run = try PendingMaintenanceRequest(host: "server", mode: .run, strategies: [.packageCache])
        inconsistent = try object(mode: "run", status: "ran")
        rows = try XCTUnwrap(inconsistent["strategies"] as? [[String: Any]])
        rows[0]["inventory_complete"] = false
        inconsistent["strategies"] = rows
        XCTAssertThrowsError(try ServerMaintenanceResult.parse(.init(exitCode: 0, output: encoded(inconsistent)), for: run))
    }

    func testLegacyErrorEligibilityStaysUnknownWhileKnownActionsRemainVisible() throws {
        let request = try PendingMaintenanceRequest(host: "server", mode: .run, strategies: [.packageCache])
        for status in ["partial", "failed", "cancelled"] {
            var legacy = try object(mode: "run", status: "ran")
            legacy["status"] = status
            legacy["cancellation"] = ["requested": status == "cancelled"]
            let unknown = try ServerMaintenanceResult.parse(.init(exitCode: 1, output: encoded(legacy)), for: request)
            XCTAssertFalse(unknown.strategies[0].eligibilityIsKnown(in: status))
            XCTAssertEqual(unknown.strategies[0].removedCount, 1)
            XCTAssertEqual(unknown.removedFileBytes, 8192)
            var rows = try XCTUnwrap(legacy["strategies"] as? [[String: Any]])
            rows[0]["inventory_complete"] = true
            legacy["strategies"] = rows
            let known = try ServerMaintenanceResult.parse(.init(exitCode: 1, output: encoded(legacy)), for: request)
            XCTAssertTrue(known.strategies[0].eligibilityIsKnown(in: status))
            XCTAssertEqual(known.strategies[0].removedCount, 1)
        }
        let legacySuccess = try ServerMaintenanceResult.parse(.init(exitCode: 0, output: fixture(mode: "run", status: "ran")), for: request)
        XCTAssertTrue(legacySuccess.strategies[0].eligibilityIsKnown(in: "ran"))
    }

    func testSuccessfulOverallStatusCannotContainUnknownOrFailedStrategyRows() throws {
        for status in ["skipped", "planned", "ran"] {
            let mode = status == "planned" ? "scan" : "run"
            let selected: [ServerMaintenanceStrategy] = [.packageCache, .rotatedLogs]
            let request = try PendingMaintenanceRequest(host: "server", mode: mode == "scan" ? .scan : .run, strategies: selected)
            for rowStatus in ["partial", "failed"] {
                for inventory in [false, true] {
                    var malformed = try object(mode: mode, status: status)
                    var rows = try XCTUnwrap(malformed["strategies"] as? [[String: Any]])
                    rows.append(["id": "rotated-logs", "status": rowStatus, "inventory_complete": inventory,
                                 "candidate_count": 0, "removed_count": 0, "attempted_count": 0])
                    malformed["strategies"] = rows
                    // The original successful/action row stays intact, so a
                    // ran response fails specifically on the inconsistent row.
                    XCTAssertThrowsError(try ServerMaintenanceResult.parse(.init(exitCode: 0, output: encoded(malformed)), for: request),
                                         "\(status) must reject \(rowStatus), inventory_complete=\(inventory)")
                }
            }
        }
        // The reported skipped/no-eligible counterexample has complete ID
        // coverage and matching zero totals, but no eligibility proof.
        let request = try PendingMaintenanceRequest(host: "server", mode: .run, strategies: [.packageCache])
        var unknown = try object(mode: "run", status: "skipped")
        unknown["candidate_count"] = 0
        unknown["strategies"] = [["id": "package-cache", "status": "partial", "inventory_complete": false,
                                  "candidate_count": 0, "removed_count": 0, "attempted_count": 0]]
        XCTAssertThrowsError(try ServerMaintenanceResult.parse(.init(exitCode: 0, output: encoded(unknown)), for: request))
    }

    func testRawTransportAndBackendDiagnosticsNeverReachUI() async throws {
        let request = try PendingMaintenanceRequest(host: "server", mode: .scan, strategies: [.packageCache])
        let control = ServerMaintenanceControl(runner: { _, _ in
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "private /credential/path diagnostic"])
        })
        await control.perform(request)
        XCTAssertFalse(control.message?.contains("private") ?? true)
        XCTAssertFalse(control.message?.contains("/credential") ?? true)
        let output = try fixture(mode: "scan", status: "planned")
        let structured = ServerMaintenanceControl(runner: { _, _ in .init(exitCode: 0, output: output) })
        await structured.perform(request)
        XCTAssertFalse(structured.message?.contains("private") ?? true)
    }

    func testDefaultTransportRefusesToLaunchFromUnitTests() async throws {
        let request = try PendingMaintenanceRequest(host: "server", mode: .scan, strategies: [.packageCache])
        let control = ServerMaintenanceControl()
        await control.perform(request)
        XCTAssertNil(control.result)
        XCTAssertNotNil(control.message)
    }

    func testOwnedLocalChildExitIsCapturedAndReaped() async throws {
        let pid = MaintenanceFixturePID()
        let response = try await Task.detached {
            try MaintenanceSSH.capture(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf fixture; exit 7"], timeout: 2, started: { pid.set($0) })
        }.value
        XCTAssertEqual(response.exitCode, 7)
        XCTAssertEqual(response.output, "fixture")
        assertReaped(pid.value)
    }

    func testOwnedLocalChildOutputCapAndTimeoutStopAndReap() async throws {
        for (script, limit, expected) in [
            ("while :; do printf 012345678901234567890123456789; done", 128, MaintenanceCaptureFailure.Reason.outputLimit),
            ("trap '' TERM; exec /bin/sleep 5", 1024, .timeout)
        ] {
            let pid = MaintenanceFixturePID()
            do {
                _ = try await Task.detached {
                    try MaintenanceSSH.capture(executable: URL(fileURLWithPath: "/bin/sh"),
                        arguments: ["-c", script], timeout: 0.2, maxOutput: limit, started: { pid.set($0) })
                }.value
                XCTFail("Fixture should reach its bound")
            } catch let error as MaintenanceCaptureFailure {
                XCTAssertEqual(error.reason, expected)
                XCTAssertTrue(error.childExitConfirmed)
            }
            assertReaped(pid.value)
        }
    }

    func testCancellationStopsAndReapsOnlyOwnedLocalChild() async throws {
        let pid = MaintenanceFixturePID()
        let task = Task.detached {
            try MaintenanceSSH.capture(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exec /bin/sleep 5"], timeout: 2, started: { pid.set($0) })
        }
        while pid.value == nil { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must not report completion") }
        catch let error as MaintenanceCaptureFailure {
            XCTAssertEqual(error.reason, .cancelled)
            XCTAssertTrue(error.childExitConfirmed)
        }
        assertReaped(pid.value)
    }

    private func assertReaped(_ pid: Int32?, file: StaticString = #filePath, line: UInt = #line) {
        guard let pid else { return XCTFail("No owned child was launched", file: file, line: line) }
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1, file: file, line: line)
        XCTAssertEqual(errno, ECHILD, "Foundation must have reaped this owned child", file: file, line: line)
    }

    private func fixture(mode: String, status: String, strategy: String = "package-cache") throws -> String {
        let ran = status == "ran"
        let object: [String: Any] = [
            "schema_version": 1, "tool": "hoghunter-server-maintenance", "mode": mode, "manual": true,
            "dry_run": false, "pressure": false, "status": status, "reason": "private /server/path",
            "before": ["free_bytes": 60000, "total_bytes": 100000, "used_percent": 40],
            "after": ["free_bytes": 55904, "total_bytes": 100000, "used_percent": 44.096],
            "reclaimed_bytes": 0, "observed_free_delta_bytes": -4096, "removed_file_bytes": ran ? 8192 : 0,
            "candidate_count": 1, "duration_seconds": 0.1,
            "lock": ran ? ["acquired": true, "released": true] : ["acquired": false],
            "cancellation": ["requested": false],
            "strategies": [["id": strategy, "status": status, "candidate_count": 1,
                            "removed_count": ran && strategy == "package-cache" ? 1 : 0,
                            "attempted_count": ran && strategy == "docker-images" ? 1 : 0]]
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func object(mode: String, status: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fixture(mode: mode, status: status).utf8)) as? [String: Any])
    }

    private func encoded(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}

private actor MaintenanceCommandRecorder {
    var arguments: [String] = []
    var count = 0
    func record(host: String, args: [String]) { arguments = args; count += 1 }
}
private actor MaintenanceGate {
    var count = 0
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { count += 1; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private final class MaintenanceFixturePID: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: Int32?
    func set(_ value: Int32) { lock.lock(); pid = value; lock.unlock() }
    var value: Int32? { lock.lock(); defer { lock.unlock() }; return pid }
}
