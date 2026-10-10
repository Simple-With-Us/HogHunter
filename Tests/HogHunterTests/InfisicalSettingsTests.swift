import Security
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
/// real Infisical service, and no credential is needed.  The stub records
/// every request (method, path, JSON body) and the tests assert on the
/// recording afterwards -- nothing is asserted or force-unwrapped on the
/// URLSession callback thread.

private final class StubURLProtocol: URLProtocol {
    struct Recorded {
        var method: String?
        var path: String?
        var body: [String: Any]?
        var query: [String: String]
    }

    private static let lock = NSLock()
    private static var recorded: [Recorded] = []
    private static var notes: [String: String] = [:]
    /// (statusCode, body) by request.  Must not throw, assert, or
    /// force-unwrap: it runs on the URLSession callback thread.
    static var handler: ((URLRequest) -> (Int, Data))?

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        recorded = []
        notes = [:]
        handler = nil
    }

    static func record(_ entry: Recorded) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(entry)
    }

    static func takeRecorded() -> [Recorded] {
        lock.lock(); defer { lock.unlock() }
        let out = recorded
        recorded = []
        return out
    }

    static func note(_ value: String, for key: String) {
        lock.lock(); defer { lock.unlock() }
        notes[key] = value
    }

    static func takeNotes() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return notes
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// httpBody is not always populated on the request the protocol
    /// receives, so fall back to draining httpBodyStream.
    private static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4096)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override func startLoading() {
        let body = Self.bodyData(of: request).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        Self.record(Recorded(
            method: request.httpMethod,
            path: request.url?.path,
            body: body,
            query: Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        ))
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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
            credentialProvider: { InfisicalCredential(clientId: "id", clientSecret: "secret", projectId: "00000000-1111-2222-3333-444444444444") }
        )
    }

    /// Routes login -> token and secrets/raw -> three keys.  No assertions
    /// inside: everything asserted is recorded for the test thread.
    private func loginHandler() -> (URLRequest) -> (Int, Data) {
        { [weak self] request in
            guard let self else { return (500, Data()) }
            switch request.url?.path {
            case "/api/v1/auth/universal-auth/login":
                return (200, self.json(["accessToken": "test-token"]))
            case "/api/v3/secrets/raw":
                return (200, self.json(["secrets": [
                    ["secretKey": "hoghunter.refreshInterval", "secretValue": "7"],
                    ["secretKey": "hoghunter.alertThresholdPercent", "secretValue": "250"],
                    ["secretKey": "hoghunter.reclaim.criticalFreeGb", "secretValue": "20"],
                ]]))
            default:
                return (404, Data())
            }
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

        let calls = StubURLProtocol.takeRecorded()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].method, "POST")
        XCTAssertEqual(calls[0].path, "/api/v1/auth/universal-auth/login")
        XCTAssertEqual(calls[0].body?["clientId"] as? String, "id")
        XCTAssertEqual(calls[1].path, "/api/v3/secrets/raw")

        await fulfillment(of: [posted], timeout: 1)
    }

    // MARK: - Runtime reads make zero network calls after init

    @MainActor
    func testRuntimeReadsMakeZeroNetworkCallsAfterInit() async {
        StubURLProtocol.handler = loginHandler()
        let store = InfisicalStore()
        let settings = makeSettings(store: store)
        await settings.bootstrap()

        _ = StubURLProtocol.takeRecorded()

        for _ in 0..<20 {
            _ = store.string(for: "hoghunter.refreshInterval")
            _ = store.double(for: "hoghunter.alertThresholdPercent")
            _ = store.int(for: "hoghunter.alertSustainedMinutes")
            _ = store.bool(for: "hoghunter.settingsRefreshMinutes")
        }

        XCTAssertEqual(
            StubURLProtocol.takeRecorded().count, 0,
            "runtime reads must never hit the network"
        )
    }

    // MARK: - Write-through PATCHes Infisical before the cache

    @MainActor
    func testWriteThroughPatchesBeforeCacheUpdate() async throws {
        let store = InfisicalStore()
        StubURLProtocol.handler = { [weak self] request in
            guard let self else { return (500, Data()) }
            switch request.url?.path {
            case "/api/v1/auth/universal-auth/login":
                return (200, self.json(["accessToken": "test-token"]))
            case "/api/v3/secrets/hoghunter.refreshInterval":
                // The cache must NOT have the new value yet: Infisical first.
                StubURLProtocol.note(
                    store.string(for: "hoghunter.refreshInterval") ?? "<nil>",
                    for: "cache-during-patch"
                )
                return (200, self.json(["secret": ["secretKey": "hoghunter.refreshInterval"]]))
            default:
                return (404, Data())
            }
        }
        let settings = makeSettings(store: store)

        try await settings.set("9", forKey: "hoghunter.refreshInterval")

        let notes = StubURLProtocol.takeNotes()
        XCTAssertEqual(
            notes["cache-during-patch"], "<nil>",
            "the PATCH must precede the cache update"
        )
        let calls = StubURLProtocol.takeRecorded()
        let patches = calls.filter { $0.method == "PATCH" }
        XCTAssertEqual(patches.count, 1)
        XCTAssertEqual(patches[0].path, "/api/v3/secrets/hoghunter.refreshInterval")
        XCTAssertEqual(patches[0].body?["secretValue"] as? String, "9")
        XCTAssertEqual(patches[0].body?["environment"] as? String, "prod")
        XCTAssertEqual(
            patches[0].body?["workspaceId"] as? String,
            "00000000-1111-2222-3333-444444444444"
        )
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
            guard let self else { return (500, Data()) }
            if request.url?.path == "/api/v1/auth/universal-auth/login" {
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
            guard let self else { return (500, Data()) }
            if request.url?.path == "/api/v1/auth/universal-auth/login" {
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
            StubURLProtocol.note("called", for: "network-used")
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
        XCTAssertNil(StubURLProtocol.takeNotes()["network-used"])
    }

    @MainActor
    func testSelectedProjectRoutesReadAndWriteRequests() async throws {
        let selectedProject = "11111111-2222-3333-4444-555555555555"
        StubURLProtocol.handler = { [weak self] request in
            guard let self else { return (500, Data()) }
            if request.url?.path == "/api/v1/auth/universal-auth/login" {
                return (200, self.json(["accessToken": "synthetic-token"]))
            }
            if request.httpMethod == "PATCH" { return (200, self.json([:])) }
            return (200, self.json(["secrets": []]))
        }
        let settings = InfisicalSettings(
            client: InfisicalClient(session: makeSession()), store: InfisicalStore(),
            credentialProvider: { nil }, credentialWriter: { _ in }, credentialRemover: {}
        )
        try await settings.saveCredential(clientId: "synthetic-id", clientSecret: "synthetic-secret", projectId: selectedProject)
        try await settings.set("9", forKey: InfisicalKey.refreshInterval)
        let calls = StubURLProtocol.takeRecorded()
        let fetch = try XCTUnwrap(calls.first { $0.path == "/api/v3/secrets/raw" })
        XCTAssertEqual(fetch.query["workspaceId"], selectedProject)
        XCTAssertEqual(fetch.query["environment"], "prod")
        let patch = try XCTUnwrap(calls.first { $0.method == "PATCH" })
        XCTAssertEqual(patch.body?["workspaceId"] as? String, selectedProject)
        XCTAssertEqual(patch.body?["environment"] as? String, "prod")
    }

    /// The dev and staging environments are retired (owner, 2026-10-10).  The
    /// environment is a constant, not a setting, so this pins it: a change
    /// back to a non-prod environment has to break a test first.
    @MainActor
    func testEnvironmentIsProdOnly() {
        XCTAssertEqual(InfisicalSettings.environment, "prod")
    }

    /// The Advanced pane note is built from the same constant, so it names
    /// the environment the app reads and never a retired one.
    @MainActor
    func testCredentialNoticeNamesTheActiveEnvironment() {
        XCTAssertTrue(InfisicalSettings.credentialNotice.hasPrefix("Uses the prod environment."))
        XCTAssertFalse(InfisicalSettings.credentialNotice.contains("dev"))
    }

    @MainActor
    func testHTTPResponseBodyIsNotExposedInStatus() async {
        StubURLProtocol.handler = { _ in (403, Data("synthetic-private-response".utf8)) }
        let settings = makeSettings()
        await settings.bootstrap()
        XCTAssertEqual(settings.lastError, "Infisical request failed (HTTP 403)")
    }

    // MARK: - Keychain prompt latch

    func testKeychainLatchTreatsOnlyAnswersAsTerminal() {
        XCTAssertTrue(InfisicalSettings.isTerminalKeychainStatus(errSecSuccess))
        XCTAssertTrue(InfisicalSettings.isTerminalKeychainStatus(errSecItemNotFound))
        XCTAssertFalse(InfisicalSettings.isTerminalKeychainStatus(errSecInteractionNotAllowed))
        XCTAssertFalse(InfisicalSettings.isTerminalKeychainStatus(errSecAuthFailed))
    }

    /// An injected credential leaves the memory cache empty.  The timer
    /// must still refresh, and it must not consult the Keychain.
    @MainActor
    func testInjectedCredentialRefreshesWithoutMemoryCache() async {
        StubURLProtocol.handler = loginHandler()
        var reads = 0
        let settings = makeSettings()
        settings.keychainReader = {
            reads += 1
            return KeychainCredentialRead(credential: nil, terminal: true)
        }

        await settings.refreshIfDue()

        XCTAssertTrue(settings.isConfigured)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(StubURLProtocol.takeRecorded().count, 2)
    }

    @MainActor
    func testMissingInjectedCredentialSkipsBackgroundRefresh() async {
        StubURLProtocol.handler = { _ in
            StubURLProtocol.note("called", for: "network-used")
            return (500, Data())
        }
        let settings = InfisicalSettings(
            client: InfisicalClient(session: makeSession()),
            store: InfisicalStore(),
            credentialProvider: { nil }
        )

        await settings.refreshIfDue()

        XCTAssertFalse(settings.isConfigured)
        XCTAssertNil(StubURLProtocol.takeNotes()["network-used"])
    }

    @MainActor
    func testTransientKeychainMissStaysRetryable() async {
        var reads = 0
        var terminal = false
        var credential: InfisicalCredential?
        StubURLProtocol.handler = { _ in
            StubURLProtocol.note("called", for: "network-used")
            return (500, Data())
        }
        let settings = InfisicalSettings(
            client: InfisicalClient(session: makeSession()),
            store: InfisicalStore()
        )
        settings.keychainReader = {
            reads += 1
            return KeychainCredentialRead(credential: credential, terminal: terminal)
        }

        await settings.refreshIfDue()
        XCTAssertFalse(settings.isConfigured)
        XCTAssertEqual(reads, 1)
        XCTAssertNil(StubURLProtocol.takeNotes()["network-used"])

        await settings.refreshIfDue()
        XCTAssertEqual(reads, 2)
        XCTAssertFalse(settings.isConfigured)
        XCTAssertNil(StubURLProtocol.takeNotes()["network-used"])

        terminal = true
        credential = InfisicalCredential(
            clientId: "id",
            clientSecret: "secret",
            projectId: "00000000-1111-2222-3333-444444444444"
        )
        StubURLProtocol.handler = loginHandler()
        await settings.refreshIfDue()
        XCTAssertTrue(settings.isConfigured)
        XCTAssertEqual(reads, 3)

        await settings.refresh()
        XCTAssertEqual(reads, 3, "a cached credential must not re-read the Keychain")
    }

    @MainActor
    func testAbsentKeychainItemDoesNotReread() async {
        var reads = 0
        let settings = InfisicalSettings(
            client: InfisicalClient(session: makeSession()),
            store: InfisicalStore()
        )
        settings.keychainReader = {
            reads += 1
            return KeychainCredentialRead(credential: nil, terminal: true)
        }

        await settings.refreshIfDue()
        await settings.refreshIfDue()
        await settings.refresh()

        XCTAssertFalse(settings.isConfigured)
        XCTAssertEqual(reads, 1)
    }
}
