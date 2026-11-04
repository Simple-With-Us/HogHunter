import XCTest
@testable import HogHunter

/// The app's own SSH connection: dead-socket classification, the discard-
/// then-create-fresh recovery, and the socket each host maps to.
final class SSHConnectionTests: XCTestCase {

    // MARK: - Failure classification

    /// The exact failure text the panel showed on 2026-11-04, when the
    /// server connection died during a period of host IO saturation and
    /// every poll and every Retry failed against the same dead socket for
    /// hours, leaving a stale full-disk reading on screen.
    func testTheIncidentFailureIsADeadSocket() {
        XCTAssertTrue(SSHConnection.isDeadSocketFailure(
            "mux_client_request_session: read from master failed: Broken pipe"))
    }

    func testEquivalentDeadMasterFailuresAreDeadSockets() {
        XCTAssertTrue(SSHConnection.isDeadSocketFailure(
            "mux_client_request_session: read from master failed: Connection reset by peer"))
        XCTAssertTrue(SSHConnection.isDeadSocketFailure(
            "Control socket connect(/Users/jay/Library/Application Support/HogHunter/SSH/mux-1a2b): Connection refused"))
        XCTAssertTrue(SSHConnection.isDeadSocketFailure(
            "ssh: control socket is not running"))
    }

    /// A dead socket is a local failure with a local remedy.  Server and
    /// network failures must not be classified as one: discarding a socket
    /// is not their fix, and callers report them as the server being
    /// unreachable.
    func testServerAndNetworkFailuresAreNotDeadSockets() {
        XCTAssertFalse(SSHConnection.isDeadSocketFailure(
            "ssh: connect to host 167.233.254.55 port 22: Connection refused"))
        XCTAssertFalse(SSHConnection.isDeadSocketFailure(
            "ssh: connect to host fleet port 22: Operation timed out"))
        XCTAssertFalse(SSHConnection.isDeadSocketFailure(
            "jay@fleet: Permission denied (publickey)."))
        XCTAssertFalse(SSHConnection.isDeadSocketFailure(
            "ssh: Could not resolve hostname fleet: nodename nor servname provided, or not known"))
        XCTAssertFalse(SSHConnection.isDeadSocketFailure(
            "Failed to decode server snapshot: The data couldn't be read because it isn't in the correct format."))
        XCTAssertFalse(SSHConnection.isDeadSocketFailure(""))
    }

    // MARK: - Socket derivation

    func testSocketNamesAreStablePerHostAndDistinctAcrossHosts() {
        let dir = URL(fileURLWithPath: "/tmp/hoghunter-test")
        XCTAssertEqual(
            SSHConnection.controlSocketURL(forHost: "fleet", in: dir),
            SSHConnection.controlSocketURL(forHost: "fleet", in: dir))
        XCTAssertNotEqual(
            SSHConnection.controlSocketURL(forHost: "fleet", in: dir),
            SSHConnection.controlSocketURL(forHost: "other", in: dir))
    }

    func testSocketNamesCarryNothingFromTheHostString() {
        // A host string can contain `@`, `:` and `/`; none of it may leak
        // into the socket path, or the path stops being one file inside one
        // directory.
        let url = SSHConnection.controlSocketURL(
            forHost: "jay@fleet.example.com:2222/weird",
            in: URL(fileURLWithPath: "/tmp/hoghunter-test"))
        XCTAssertEqual(url.deletingLastPathComponent().path, "/tmp/hoghunter-test")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("mux-"))
        XCTAssertFalse(url.lastPathComponent.contains("@"))
        XCTAssertFalse(url.lastPathComponent.contains(":"))
    }

    func testControlPathOptionQuotesTheSpacedPath() {
        // The real socket directory sits under Application Support, whose
        // name contains spaces; ssh's option parser rejects the unquoted
        // value ("extra arguments at end of line"), so the option must
        // carry the path in double quotes.
        let url = SSHConnection.controlSocketURL(
            forHost: "server",
            in: URL(fileURLWithPath: "/tmp/Application Support/HogHunter/SSH"))
        XCTAssertEqual(
            SSHConnection.controlPathOption(url),
            "ControlPath=\"\(url.path)\"")
    }

    // MARK: - Recovery

    private final class Recorder: @unchecked Sendable {
        var attempts = 0
        var discards = 0
    }

    private func deadSocketError() -> NSError {
        NSError(domain: "test", code: 255, userInfo: [
            NSLocalizedDescriptionKey: "mux_client_request_session: read from master failed: Broken pipe"
        ])
    }

    /// The recovery contract: the dead master is discarded before the retry,
    /// the retry is a fresh attempt, and one discard plus one retry is all
    /// that ever happens — never a loop against a possibly-dead socket.
    func testRecoveryDiscardsOnceThenRetries() async throws {
        let recorder = Recorder()
        let value = try await SSHConnection.retryingOnceOnDeadSocket(
            attempt: {
                recorder.attempts += 1
                if recorder.attempts == 1 { throw self.deadSocketError() }
                return 42
            },
            discard: { recorder.discards += 1 }
        )
        XCTAssertEqual(value, 42)
        XCTAssertEqual(recorder.attempts, 2)
        XCTAssertEqual(recorder.discards, 1)
    }

    func testRecoveryDoesNotDiscardForAnOrdinaryFailure() async {
        let recorder = Recorder()
        do {
            _ = try await SSHConnection.retryingOnceOnDeadSocket(
                attempt: { () async throws -> Int in
                    recorder.attempts += 1
                    throw NSError(domain: "test", code: 61, userInfo: [
                        NSLocalizedDescriptionKey: "ssh: connect to host fleet port 22: Connection refused"
                    ])
                },
                discard: { recorder.discards += 1 }
            )
            XCTFail("the ordinary failure should have propagated")
        } catch {
            XCTAssertEqual(recorder.attempts, 1)
            XCTAssertEqual(recorder.discards, 0)
        }
    }

    func testRecoveryRetriesOnlyOnceWhenTheSocketFailureRepeats() async {
        let recorder = Recorder()
        do {
            _ = try await SSHConnection.retryingOnceOnDeadSocket(
                attempt: { () async throws -> Int in
                    recorder.attempts += 1
                    throw self.deadSocketError()
                },
                discard: { recorder.discards += 1 }
            )
            XCTFail("the repeated failure should have propagated")
        } catch {
            XCTAssertEqual(recorder.attempts, 2, "one attempt and one fresh attempt, never a loop")
            XCTAssertEqual(recorder.discards, 1)
            XCTAssertTrue(SSHConnection.isDeadSocketFailure(error))
        }
    }

    // MARK: - Store staleness

    private final class FetchScript: @unchecked Sendable {
        var failing = false
    }

    /// After a successful reading, a failing refresh keeps the reading and
    /// marks it stale.  That pair is what stops an old reading from
    /// presenting as live data while the server cannot be read.
    @MainActor
    func testStoreMarksTheRetainedSnapshotStaleWhenRefreshFails() async throws {
        let snapshot = VPSStatusSnapshot(
            generatedAt: "2026-11-04T15:00:00Z",
            host: "fleet-hetzner-nbg1",
            devices: ["root": VPSDevice(mount: "/", freeBytes: 150 * 1024 * 1024 * 1024, note: "root")]
        )
        let script = FetchScript()
        let store = VPSStatusStore(initialHost: "fleet", fetcher: { _ in
            if script.failing { throw self.deadSocketError() }
            return snapshot
        })

        store.fetch(force: true)
        for _ in 0..<100 where store.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(store.snapshot)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isStale)

        script.failing = true
        store.fetch(force: true)
        for _ in 0..<100 where store.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(store.snapshot, "the last good reading is retained")
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.isStale)
    }
}
