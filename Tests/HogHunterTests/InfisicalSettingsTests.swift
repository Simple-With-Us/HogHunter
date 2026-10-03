import XCTest
@testable import HogHunter

/// Tests for the Infisical SOT contract (see INFISICAL.md):
/// - startup load populates the cache
/// - runtime reads make zero network calls after init
/// - write-through PATCHes Infisical before touching the local cache
/// - a failed refresh keeps serving last-known-good
/// - a failed write-through rejects (cache untouched)
///
/// The network is fully stubbed via StubURLProtocol; no test touches the
/// real Infisical service, and no credential is needed.

private final class StubURLProtocol: URLProtocol {
    struct Recorded {
        var method: String?
        var path: String?
        var body: [String: Any]?
    }

    static let lock = NSLock()
    static var recorded: [Recorded] = []
    static var notes: [String: String] = [:]
    /// (statusCode, body) or throws to simulate a transport failure.
    static var handler: ((URLRequest) throws -> (Int, Data))?

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        recorded = []
        notes = [:]
        handler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body: [String: Any]? = request.httpBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        Self.lock.lock()
        Self.recorded.append(Recorded(
            method: request.httpMethod,
            path: request.url?.path,
            body: body
        ))
        Self.lock.unlock()
        do {
            guard let handler = Self.handler else {
                throw NSError(domain: "StubURLProtocol", code: -1, userInfo: nil)
            }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: [:]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func note(_ value: String, for key: String) {
        lock.lock(); defer { lock.unlock() }
        notes[key] = value
    }
}

final class InfisicalSettingsTests: XCTestCase {

    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    @MainActor
    private func makeSettings(store: InfisicalStore = InfisicalStore()) -> InfisicalSettings {
        let client = InfisicalClient(session: makeSession())
        return InfisicalSettings(
            client: client,
            store: store,
            credentialProvider: { InfisicalCredential(clientId: "id", clientSecret: "secret") }
        )
    }

    private func loginHandler() -> (URLRequest) throws -> (Int, Data) {
        { [weak self] request in
            guard let self else { throw NSError(domain: "test", code: -1, userInfo: nil) }
            let path = request.url!.path
            if path == "/api/v1/auth/universal-auth/login" {
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                XCTAssertEqual(body["clientId"] as? String, "id")
                XCTAssertEqual(body["clientSecret"] as? String, "secret")
                return (200, self.json(["accessToken": "test-token"]))
            }
            if path == "/api/v3/secrets/raw" {
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer test-token"
                )
                return (200, self.json(["secrets": [
                    ["secretKey": "hoghunter.refreshInterval", "secretValue": "7"],
                    ["secretKey": "hoghunter.alertThresholdPercent", "secretValue": "250"],
                    ["secretKey": "hoghunter.reclaim.criticalFreeGb", "secretValue": "20"],
                ]]))
            }
            return (404, Data())
        }
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    // MARK: - Startup load populates the cache

    @MainActor
    func testStartupLoadPopulatesCache() async {
        StubURLProtocol.handler = loginHandler()
        let store = InfisicalStore()
        let settings = makeSettings(store: store)

        let posted = expectation(forNotification: .infisicalSettingsDidRefresh, object: settings)
        await settings.bootstrap()

        XCTAssertTrue(settings.isConfigured)
        XCTAssertEqual(store.string(for: "hoghunter.refreshInterval"), "7")
        XCTAssertEqual(store.double(for: "hoghunter.refreshInterval"), 7)
        XCTAssertEqual(store.double(for: "hoghunter.alertThresholdPercent"), 250)
        XCTAssertEqual(store.double(for: "hoghunter.reclaim.criticalFreeGb"), 20)
        XCTAssertNotNil(settings.lastRefresh)
        XCTAssertNil(settings.lastError)
        await fulfillment(of: [posted], timeout: 1)
    }

    // MARK: - Runtime reads make zero network calls after init

    @MainActor
    func testRuntimeReadsMakeZeroNetworkCallsAfterInit() async {
        StubURLProtocol.handler = loginHandler()
        let store = InfisicalStore()
        let settings = makeSettings(store: store)
        await settings.bootstrap()

        StubURLProtocol.lock.lock()
        StubURLProtocol.recorded = []
        StubURLProtocol.lock.unlock()

        for _ in 0..<20 {
            _ = store.string(for: "hoghunter.refreshInterval")
            _ = store.double(for: "hoghunter.alertThresholdPercent")
            _ = store.int(for: "hoghunter.alertSustainedMinutes")
            _ = store.bool(for: "hoghunter.settingsRefreshMinutes")
        }

        StubURLProtocol.lock.lock()
        let calls = StubURLProtocol.recorded.count
        StubURLProtocol.lock.unlock()
        XCTAssertEqual(calls, 0, "runtime reads must never hit the network")
    }

    // MARK: - Write-through PATCHes Infisical before the cache

    @MainActor
    func testWriteThroughPatchesBeforeCacheUpdate() async throws {
        let store = InfisicalStore()
        StubURLProtocol.handler = { [weak self] request in
            guard let self else { throw NSError(domain: "test", code: -1, userInfo: nil) }
            let path = request.url!.path
            if path == "/api/v1/auth/universal-auth/login" {
                return (200, self.json(["accessToken": "test-token"]))
            }
            if path == "/api/v3/secrets/hoghunter.refreshInterval" {
                XCTAssertEqual(request.httpMethod, "PATCH")
                // The cache must NOT have the new value yet: Infisical first.
                StubURLProtocol.note(
                    store.string(for: "hoghunter.refreshInterval") ?? "<nil>",
                    for: "cache-during-patch"
                )
                let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                XCTAssertEqual(body["secretValue"] as? String, "9")
                XCTAssertEqual(body["environment"] as? String, "dev")
                XCTAssertEqual(
                    body["workspaceId"] as? String,
                    "c1df65f2-adb5-4d64-93c0-f47f969feea1"
                )
                return (200, self.json(["secret": ["secretKey": "hoghunter.refreshInterval"]]))
            }
            return (404, Data())
        }
        let settings = makeSettings(store: store)

        try await settings.set("9", forKey: "hoghunter.refreshInterval")

        StubURLProtocol.lock.lock()
        let cacheDuringPatch = StubURLProtocol.notes["cache-during-patch"]
        let patchCalls = StubURLProtocol.recorded.filter {
            ($0.path ?? "").hasPrefix("/api/v3/secrets/")
        }
        StubURLProtocol.lock.unlock()
        XCTAssertEqual(cacheDuringPatch, "<nil>", "PATCH must precede the cache update")
        XCTAssertEqual(patchCalls.count, 1)
        XCTAssertEqual(store.string(for: "hoghunter.refreshInterval"), "9")
        XCTAssertNil(settings.lastError)
    }

    // MARK: - Failed refresh keeps last-known-good

    @MainActor
    func testFailedRefreshKeepsLastKnownGood() async {
        StubURLProtocol.handler = loginHandler()
        let store = InfisicalStore()
        let settings = makeSettings(store: store)
        await settings.bootstrap()
        XCTAssertEqual(store.string(for: "hoghunter.refreshInterval"), "7")

        // Now the secrets endpoint fails; the login still succeeds.
        StubURLProtocol.handler = { [weak self] request in
            guard let self else { throw NSError(domain: "test", code: -1, userInfo: nil) }
            if request.url!.path == "/api/v1/auth/universal-auth/login" {
                return (200, self.json(["accessToken": "test-token"]))
            }
            return (500, self.json(["message": "boom"]))
        }
        await settings.refresh()

        XCTAssertEqual(
            store.string(for: "hoghunter.refreshInterval"), "7",
            "a failed refresh must not clobber the cache"
        )
        XCTAssertNotNil(settings.lastError)
    }

    // MARK: - Failed write-through rejects

    @MainActor
    func testFailedWriteThroughRejects() async {
        let store = InfisicalStore()
        store.set("7", forKey: "hoghunter.refreshInterval")
        StubURLProtocol.handler = { [weak self] request in
            guard let self else { throw NSError(domain: "test", code: -1, userInfo: nil) }
            if request.url!.path == "/api/v1/auth/universal-auth/login" {
                return (200, self.json(["accessToken": "test-token"]))
            }
            return (500, self.json(["message": "boom"]))
        }
        let settings = makeSettings(store: store)

        do {
            try await settings.set("9", forKey: "hoghunter.refreshInterval")
            XCTFail("a failed PATCH must throw")
        } catch {
            // Expected.
        }

        XCTAssertEqual(
            store.string(for: "hoghunter.refreshInterval"), "7",
            "a failed write must leave the cache untouched"
        )
        XCTAssertNotNil(settings.lastError)
    }

    // MARK: - Unconfigured bootstrap is inert

    @MainActor
    func testUnconfiguredBootstrapLeavesDefaults() async {
        StubURLProtocol.handler = { _ in
            XCTFail("no network call should happen when unconfigured")
            return (500, Data())
        }
        let store = InfisicalStore()
        let client = InfisicalClient(session: makeSession())
        let settings = InfisicalSettings(
            client: client,
            store: store,
            credentialProvider: { nil }
        )

        await settings.bootstrap()
        await settings.refresh()

        XCTAssertFalse(settings.isConfigured)
        XCTAssertEqual(store.count, 0)
        XCTAssertNil(settings.lastError)
    }
}
