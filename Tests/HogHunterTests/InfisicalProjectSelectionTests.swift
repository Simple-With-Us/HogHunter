import XCTest
@testable import HogHunter

/// Synthetic credentials only.  This suite never uses URLSession or the Keychain.
@MainActor
private final class ProjectClient: InfisicalServing {
    var loginCount = 0
    var fetchedProjects: [String] = []
    var writtenProjects: [String] = []
    var login: () async throws -> String = { "synthetic-token" }
    var fetch: (String) async throws -> [String: String] = { _ in [:] }
    var write: (String) async throws -> Void = { _ in }

    func login(clientId: String, clientSecret: String) async throws -> String {
        loginCount += 1
        return try await login()
    }

    func fetchSecrets(accessToken: String, environment: String, projectId: String) async throws -> [String: String] {
        fetchedProjects.append(projectId)
        return try await fetch(projectId)
    }

    func upsertSecret(accessToken: String, environment: String, key: String, value: String, projectId: String) async throws {
        writtenProjects.append(projectId)
        try await write(projectId)
    }
}

@MainActor
private final class ProjectGate<Value> {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ entered: XCTestExpectation) { self.entered = entered }

    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation {
            continuation = $0
            entered.fulfill()
        }
    }

    func finish(_ result: Result<Value, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

@MainActor
private final class ProjectFixture {
    static let a = "00000000-1111-2222-3333-444444444444"
    static let b = "11111111-2222-3333-4444-555555555555"
    static let c = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    static let oldValues = [
        InfisicalKey.refreshInterval: "7",
        InfisicalKey.alertThresholdPercent: "450",
        InfisicalKey.alertSustainedMinutes: "9",
        InfisicalKey.alertWebhookURL: "https://synthetic.invalid/project-a",
    ]

    let client = ProjectClient()
    let cache = InfisicalStore()
    var persisted: InfisicalCredential? = InfisicalCredential(clientId: "synthetic-id", clientSecret: "synthetic-secret", projectId: ProjectFixture.a)
    var writes = 0
    var writeError: Error?
    var removeError: Error?
    lazy var settings = InfisicalSettings(
        client: client, store: cache,
        credentialProvider: { [weak self] in self?.persisted },
        credentialWriter: { [unowned self] credential in
            if let error = writeError { throw error }
            writes += 1
            persisted = credential
        },
        credentialRemover: { [unowned self] in
            if let error = removeError { throw error }
            persisted = nil
        }
    )

    init() {
        client.fetch = { project in project == Self.a ? Self.oldValues : [:] }
    }

    func save(_ project: String = b) async throws {
        try await settings.saveCredential(clientId: "new-synthetic-id", clientSecret: "new-synthetic-secret", projectId: project)
    }
}

final class InfisicalProjectSelectionTests: XCTestCase {
    func testLegacyCredentialDecodesWithoutInferringProject() throws {
        let legacy = Data(#"{"clientId":"synthetic-id","clientSecret":"synthetic-secret"}"#.utf8)
        let credential = try JSONDecoder().decode(InfisicalCredential.self, from: legacy)
        XCTAssertNil(credential.projectId)
        XCTAssertEqual(credential.effectiveProjectId, "")
        XCTAssertFalse(credential.isComplete)
        let selected = InfisicalCredential(clientId: "synthetic-id", clientSecret: "synthetic-secret", projectId: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        let roundTrip = try JSONDecoder().decode(InfisicalCredential.self, from: JSONEncoder().encode(selected))
        XCTAssertEqual(roundTrip.effectiveProjectId, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    }

    @MainActor
    func testMissingBlankOrInvalidStoredProjectCannotAuthenticate() async {
        for project in [nil, "", "  ", "not-a-project"] as [String?] {
            let f = ProjectFixture()
            f.persisted?.projectId = project
            await f.settings.bootstrap()
            await f.settings.refresh()
            XCTAssertFalse(f.settings.isConfigured)
            XCTAssertEqual(f.settings.projectId, "")
            XCTAssertEqual(f.client.loginCount, 0)
            XCTAssertEqual(f.writes, 0)
            XCTAssertEqual(f.cache.snapshot.projectId, InfisicalStore.localProjectId)
        }
    }

    @MainActor
    func testValidationAndPersistencePrecedeActivation() async throws {
        let f = ProjectFixture()
        await f.settings.bootstrap()
        let before = f.settings.connectionGeneration
        f.client.fetch = { project in
            XCTAssertEqual(project, ProjectFixture.b)
            XCTAssertEqual(f.settings.projectId, ProjectFixture.a)
            XCTAssertEqual(f.writes, 0)
            XCTAssertEqual(f.cache.snapshot.values, ProjectFixture.oldValues)
            return [InfisicalKey.refreshInterval: "11"]
        }
        try await f.settings.saveCredential(clientId: "  new-synthetic-id\n", clientSecret: "  synthetic-secret  ", projectId: " \(ProjectFixture.b)\n")
        XCTAssertEqual(f.persisted?.clientId, "new-synthetic-id")
        XCTAssertEqual(f.persisted?.clientSecret, "  synthetic-secret  ", "Secret bytes must not be trimmed")
        XCTAssertEqual(f.persisted?.projectId, ProjectFixture.b)
        XCTAssertEqual(f.settings.projectId, ProjectFixture.b)
        XCTAssertNotEqual(f.settings.connectionGeneration, before)
        XCTAssertEqual(f.cache.snapshot.values, [InfisicalKey.refreshInterval: "11"])
        XCTAssertNil(f.cache.string(for: InfisicalKey.alertWebhookURL))
        XCTAssertFalse(f.settings.isSaving)
        XCTAssertNil(f.settings.lastError)
    }

    @MainActor
    func testInvalidInputDoesNotContactServiceOrPersist() async {
        let f = ProjectFixture()
        for (id, secret, project) in [(" ", "s", ProjectFixture.b), ("id", " \n", ProjectFixture.b), ("id", "s", "not-a-project-id"), ("id", "s", "")] {
            do {
                try await f.settings.saveCredential(clientId: id, clientSecret: secret, projectId: project)
                XCTFail("Invalid configuration must fail locally")
            } catch {}
        }
        XCTAssertEqual(f.client.loginCount, 0)
        XCTAssertEqual(f.writes, 0)
        XCTAssertFalse(f.settings.isSaving)
    }

    @MainActor
    func testFailedAuthenticationProjectAccessAndPersistenceKeepWorkingSetup() async {
        for failure in 0..<3 {
            let f = ProjectFixture()
            await f.settings.bootstrap()
            let before = f.settings.connectionGeneration
            let lastRefresh = f.settings.lastRefresh
            let error = InfisicalError.httpStatus(403, "synthetic-private-response")
            if failure == 0 { f.client.login = { throw error } }
            if failure == 1 { f.client.fetch = { _ in throw error } }
            if failure == 2 { f.writeError = NSError(domain: "synthetic-private-error", code: 1) }
            do { try await f.save(); XCTFail("Failed validation/persistence must throw") } catch {}
            XCTAssertEqual(f.persisted?.effectiveProjectId, ProjectFixture.a)
            XCTAssertEqual(f.settings.projectId, ProjectFixture.a)
            XCTAssertEqual(f.settings.connectionGeneration, before)
            XCTAssertEqual(f.settings.lastRefresh, lastRefresh)
            XCTAssertEqual(f.cache.snapshot.values, ProjectFixture.oldValues)
            XCTAssertTrue(f.settings.isConfigured)
            XCTAssertFalse(f.settings.isSaving)
            XCTAssertEqual(f.writes, 0)
            XCTAssertFalse(f.settings.lastError?.contains("private") ?? true)
        }
    }

    @MainActor
    func testOldRefreshSuccessAndFailureCannotReplaceNewProject() async throws {
        for fails in [false, true] {
            let f = ProjectFixture()
            await f.settings.bootstrap()
            let gate = ProjectGate<[String: String]>(expectation(description: "Old fetch entered"))
            f.client.fetch = { project in project == ProjectFixture.a ? try await gate.wait() : [InfisicalKey.refreshInterval: "11"] }
            let old = Task { await f.settings.refresh() }
            await fulfillment(of: [gate.entered], timeout: 2)
            try await f.save()
            let lastRefresh = f.settings.lastRefresh
            gate.finish(fails ? .failure(InfisicalError.httpStatus(500, "synthetic-private-response")) : .success(ProjectFixture.oldValues))
            await old.value
            XCTAssertEqual(f.cache.snapshot.values, [InfisicalKey.refreshInterval: "11"])
            XCTAssertEqual(f.settings.lastRefresh, lastRefresh)
            XCTAssertNil(f.settings.lastError)
            XCTAssertFalse(f.settings.isRefreshing)
        }
    }

    @MainActor
    func testOldWriteCompletionCannotMutateNewProjectOrStatus() async throws {
        for fails in [false, true] {
            let f = ProjectFixture()
            await f.settings.bootstrap()
            let gate = ProjectGate<Void>(expectation(description: "Old write entered"))
            f.client.write = { _ in try await gate.wait() }
            let old = Task { try await f.settings.set("99", forKey: InfisicalKey.refreshInterval) }
            await fulfillment(of: [gate.entered], timeout: 2)
            try await f.save()
            gate.finish(fails ? .failure(InfisicalError.httpStatus(500, "synthetic-private-response")) : .success(()))
            do { try await old.value; XCTFail("Stale write must be rejected") } catch {}
            XCTAssertEqual(f.client.writtenProjects, [ProjectFixture.a])
            XCTAssertEqual(f.cache.count, 0)
            XCTAssertNil(f.settings.lastError)
        }
    }

    @MainActor
    func testOldWriteLoginCannotStartPatchAfterSwitch() async throws {
        let f = ProjectFixture()
        await f.settings.bootstrap()
        let gate = ProjectGate<String>(expectation(description: "Old login entered"))
        f.client.login = { try await gate.wait() }
        let old = Task { try await f.settings.set("99", forKey: InfisicalKey.refreshInterval) }
        await fulfillment(of: [gate.entered], timeout: 2)
        f.client.login = { "new-synthetic-token" }
        try await f.save()
        gate.finish(.success("old-synthetic-token"))
        do { try await old.value; XCTFail("Stale login must not start a write") } catch {}
        XCTAssertTrue(f.client.writtenProjects.isEmpty)
        XCTAssertEqual(f.cache.count, 0)
    }

    @MainActor
    func testQueuedEditAndBatchCannotFollowConnectionToNewProject() async throws {
        let f = ProjectFixture()
        await f.settings.bootstrap()
        let original = f.settings.connectionGeneration
        try await f.settings.set("8", forKey: InfisicalKey.refreshInterval, expectedGeneration: original)
        try await f.save()
        let calls = f.client.loginCount
        do {
            try await f.settings.set("99", forKey: InfisicalKey.alertSustainedMinutes, expectedGeneration: original)
            XCTFail("An old queued edit or next batch item must not reach the new project")
        } catch {}
        XCTAssertEqual(f.client.loginCount, calls)
        XCTAssertEqual(f.client.writtenProjects, [ProjectFixture.a])
        XCTAssertNil(f.settings.lastError)
    }

    @MainActor
    func testClearCancelsSaveAndItsLateCompletionCannotFinishNewerSave() async throws {
        let f = ProjectFixture()
        await f.settings.bootstrap()
        let oldGate = ProjectGate<[String: String]>(expectation(description: "First validation entered"))
        let newGate = ProjectGate<[String: String]>(expectation(description: "New validation entered"))
        f.client.fetch = { project in
            if project == ProjectFixture.b { return try await oldGate.wait() }
            return try await newGate.wait()
        }
        let old = Task { try await f.save() }
        await fulfillment(of: [oldGate.entered], timeout: 2)
        do { try await f.save(ProjectFixture.c); XCTFail("Concurrent save must be rejected") } catch {}
        try f.settings.clearCredential()
        XCTAssertFalse(f.settings.isConfigured)
        XCTAssertFalse(f.settings.isSaving)
        let newer = Task { try await f.save(ProjectFixture.c) }
        await fulfillment(of: [newGate.entered], timeout: 2)
        oldGate.finish(.success(ProjectFixture.oldValues))
        do { try await old.value; XCTFail("Cleared save must not persist") } catch {}
        XCTAssertTrue(f.settings.isSaving, "Late old defer must not clear newer save state")
        XCTAssertNil(f.persisted)
        XCTAssertEqual(f.writes, 0)
        XCTAssertNil(f.settings.lastError)
        newGate.finish(.success([InfisicalKey.refreshInterval: "12"]))
        try await newer.value
        XCTAssertEqual(f.persisted?.projectId, ProjectFixture.c)
        XCTAssertEqual(f.settings.projectId, ProjectFixture.c)
        XCTAssertFalse(f.settings.isSaving)
        XCTAssertEqual(f.writes, 1)
    }

    @MainActor
    func testClearRejectsOldRefreshAndClearFailurePreservesConnection() async throws {
        let f = ProjectFixture()
        await f.settings.bootstrap()
        f.removeError = NSError(domain: "synthetic-failure", code: 1)
        do { try f.settings.clearCredential(); XCTFail("Removal error must throw") } catch {}
        XCTAssertTrue(f.settings.isConfigured)
        XCTAssertEqual(f.cache.snapshot.values, ProjectFixture.oldValues)
        let gate = ProjectGate<[String: String]>(expectation(description: "Old fetch entered"))
        f.client.fetch = { _ in try await gate.wait() }
        let old = Task { await f.settings.refresh() }
        await fulfillment(of: [gate.entered], timeout: 2)
        f.removeError = nil
        try f.settings.clearCredential()
        gate.finish(.success(ProjectFixture.oldValues))
        await old.value
        await f.settings.refresh()
        XCTAssertFalse(f.settings.isConfigured)
        XCTAssertFalse(f.settings.isRefreshing)
        XCTAssertEqual(f.cache.count, 0)
        XCTAssertNil(f.settings.lastRefresh)
        XCTAssertNil(f.settings.lastError)
    }

    @MainActor
    private func withDefaults(_ body: (UserDefaults) async throws -> Void) async rethrows {
        let suite = "InfisicalProjectSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try await body(defaults)
    }

    @MainActor
    private func makeHogStore(_ f: ProjectFixture, _ defaults: UserDefaults) -> HogStore {
        HogStore(historyURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString), defaults: defaults, infisical: f.settings, startImmediately: false)
    }

    @MainActor
    func testSwitchToEmptyProjectResetsEffectiveAndPersistedValues() async throws {
        try await withDefaults { defaults in
            let f = ProjectFixture()
            let hog = makeHogStore(f, defaults)
            await f.settings.bootstrap()
            XCTAssertEqual(hog.alertWebhookURL, ProjectFixture.oldValues[InfisicalKey.alertWebhookURL])
            try await f.save()
            XCTAssertEqual(hog.refreshInterval, 3)
            XCTAssertEqual(hog.alertThresholdPercent, 300)
            XCTAssertEqual(hog.alertSustainedMinutes, 5)
            XCTAssertEqual(hog.alertWebhookURL, "")
            XCTAssertEqual(defaults.string(forKey: HogStore.Key.alertWebhookURL), "")
            XCTAssertEqual(defaults.string(forKey: HogStore.Key.infisicalProjectId), ProjectFixture.b)
            XCTAssertTrue(f.client.writtenProjects.isEmpty, "Applying target values must not write through")
        }
    }

    @MainActor
    func testFailedSwitchKeepsEffectiveAndPersistedValues() async {
        await withDefaults { defaults in
            let f = ProjectFixture()
            let hog = makeHogStore(f, defaults)
            await f.settings.bootstrap()
            f.writeError = NSError(domain: "synthetic-failure", code: 1)
            do { try await f.save(); XCTFail("Failed persistence must reject switch") } catch {}
            XCTAssertEqual(hog.refreshInterval, 7)
            XCTAssertEqual(hog.alertWebhookURL, ProjectFixture.oldValues[InfisicalKey.alertWebhookURL])
            XCTAssertEqual(defaults.double(forKey: HogStore.Key.refreshInterval), 7)
            XCTAssertEqual(defaults.string(forKey: HogStore.Key.infisicalProjectId), ProjectFixture.a)
        }
    }

    @MainActor
    func testSameTargetMissingKeysKeepsFallbackAndClearRemovesOldWebhook() async throws {
        try await withDefaults { defaults in
            let f = ProjectFixture()
            let hog = makeHogStore(f, defaults)
            await f.settings.bootstrap()
            f.client.fetch = { _ in [:] }
            try await f.save(ProjectFixture.a)
            XCTAssertEqual(hog.refreshInterval, 7)
            XCTAssertEqual(hog.alertWebhookURL, ProjectFixture.oldValues[InfisicalKey.alertWebhookURL])
            try f.settings.clearCredential()
            XCTAssertEqual(hog.refreshInterval, 3)
            XCTAssertEqual(hog.alertWebhookURL, "")
            XCTAssertEqual(defaults.string(forKey: HogStore.Key.alertWebhookURL), "")
            XCTAssertEqual(defaults.string(forKey: HogStore.Key.infisicalProjectId), InfisicalStore.localProjectId)
        }
    }

    @MainActor
    func testOfflineRelaunchRestoresOnlyMatchingProjectValues() async {
        for project in [ProjectFixture.a, ProjectFixture.b] {
            await withDefaults { defaults in
                defaults.set(ProjectFixture.a, forKey: HogStore.Key.infisicalProjectId)
                defaults.set(7, forKey: HogStore.Key.refreshInterval)
                defaults.set("https://synthetic.invalid/project-a", forKey: HogStore.Key.alertWebhookURL)
                let f = ProjectFixture()
                f.persisted?.projectId = project
                f.client.login = { throw InfisicalError.httpStatus(503, "") }
                let hog = makeHogStore(f, defaults)
                XCTAssertEqual(hog.alertWebhookURL, "", "Do not use a scoped webhook before resolving Keychain target")
                hog.persistForTest()
                XCTAssertEqual(defaults.double(forKey: HogStore.Key.refreshInterval), 7, "Unresolved startup must not overwrite persisted fallback")
                await f.settings.bootstrap()
                XCTAssertEqual(hog.refreshInterval, project == ProjectFixture.a ? 7 : 3)
                XCTAssertEqual(hog.alertWebhookURL, project == ProjectFixture.a ? "https://synthetic.invalid/project-a" : "")
                XCTAssertEqual(defaults.string(forKey: HogStore.Key.infisicalProjectId), project)
            }
        }
    }

    @MainActor
    func testMissingCredentialResolvesScopedFallbackToEditableLocalSettings() async {
        await withDefaults { defaults in
            defaults.set(ProjectFixture.a, forKey: HogStore.Key.infisicalProjectId)
            defaults.set(7, forKey: HogStore.Key.refreshInterval)
            defaults.set("https://synthetic.invalid/project-a", forKey: HogStore.Key.alertWebhookURL)
            let f = ProjectFixture()
            f.persisted = nil
            let hog = makeHogStore(f, defaults)
            await f.settings.bootstrap()
            XCTAssertEqual(hog.alertWebhookURL, "")
            XCTAssertEqual(hog.refreshInterval, 3)
            XCTAssertEqual(defaults.string(forKey: HogStore.Key.infisicalProjectId), InfisicalStore.localProjectId)
            hog.refreshInterval = 9
            hog.persistForTest()
            XCTAssertEqual(defaults.double(forKey: HogStore.Key.refreshInterval), 9)
            XCTAssertEqual(defaults.string(forKey: HogStore.Key.alertWebhookURL), "")
            XCTAssertEqual(f.client.loginCount, 0)
        }
    }

    @MainActor
    func testUnconfiguredLegacyLocalSettingsRemainUsable() async {
        await withDefaults { defaults in
            defaults.set(7, forKey: HogStore.Key.refreshInterval)
            defaults.set("https://synthetic.invalid/local", forKey: HogStore.Key.alertWebhookURL)
            let f = ProjectFixture()
            f.persisted = nil
            let hog = makeHogStore(f, defaults)
            await f.settings.bootstrap()
            XCTAssertEqual(hog.refreshInterval, 7)
            XCTAssertEqual(hog.alertWebhookURL, "https://synthetic.invalid/local")
            XCTAssertEqual(f.client.loginCount, 0)
        }
    }
}
