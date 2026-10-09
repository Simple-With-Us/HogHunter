import Network
import XCTest

@testable import HogHunter

/// Every network gate depends on `CompanionPeer.from(connection.endpoint)`
/// returning a numeric address for a connection the listener accepted.  If the
/// endpoint ever came back in another shape, every peer would read as untrusted
/// and every control would answer 403, while the pure address tests still
/// passed.  So this opens a real loopback socket and asks.
final class CompanionSocketPeerTests: XCTestCase {
    /// Connects to a throwaway listener on `host` and returns the endpoint the
    /// listener sees for the accepted connection.
    private func acceptedEndpoint(from host: NWEndpoint.Host) throws -> NWEndpoint? {
        let queue = DispatchQueue(label: "hoghunter.tests.socketpeer")
        let listener = try NWListener(using: .tcp, on: .any)
        let accepted = expectation(description: "connection accepted")
        let seen = CompanionLocked<NWEndpoint?>(nil)
        listener.newConnectionHandler = { connection in
            seen.value = connection.endpoint
            connection.cancel()
            accepted.fulfill()
        }
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 5)
        defer { listener.cancel() }

        let port = try XCTUnwrap(listener.port)
        let client = NWConnection(host: host, port: port, using: .tcp)
        client.start(queue: queue)
        defer { client.cancel() }
        wait(for: [accepted], timeout: 5)
        return seen.value
    }

    func testAnAcceptedIPv4LoopbackConnectionIsANumericTrustedPeer() throws {
        let endpoint = try XCTUnwrap(acceptedEndpoint(from: "127.0.0.1"))
        guard case .hostPort(let host, _) = endpoint else { return XCTFail("expected hostPort, got \(endpoint)") }
        if case .name = host { XCTFail("an accepted connection must carry a numeric address, got \(host)") }

        let peer = CompanionPeer.from(endpoint)
        XCTAssertTrue(peer.isTrusted, "loopback must be trusted or every control would be refused: \(peer)")
        XCTAssertEqual(peer.key, "127.0.0.1")
    }

    func testAnAcceptedIPv6LoopbackConnectionIsATrustedPeer() throws {
        let endpoint = try XCTUnwrap(acceptedEndpoint(from: "::1"))
        let peer = CompanionPeer.from(endpoint)
        XCTAssertTrue(peer.isTrusted, "::1 must be trusted: \(peer) from \(endpoint)")
        // A dual-stack listener may show ::1 as ::1 or, rarely, wrapped.  Either
        // way the key is stable and never "unknown".
        XCTAssertNotEqual(peer.key, CompanionPeer.unknown.key)
    }
}
