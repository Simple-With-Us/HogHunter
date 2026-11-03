import XCTest
@testable import HogHunter

/// Synthetic tokens only; persistence and transport are injected throughout.
@MainActor
private final class ScopedInfisicalClient: InfisicalServing {
    var metadata: [String: InfisicalTokenMetadata] = [:]
    var values: [String: [String: String]] = [:]
    var reads: [String] = []
    var writes: [(String, String, String)] = []
    var loginCount = 0
    var metadataHook: ((String) async throws -> InfisicalTokenMetadata)?
    var fetchHook: ((String) async throws -> [String: String])?
    var writeHook: (() async throws -> Void)?

    func login(clientId: String, clientSecret: String) async throws -> String { loginCount += 1; return "synthetic-mi" }
    func tokenMetadata(token: String) async throws -> InfisicalTokenMetadata {
        if let metadataHook { return try await metadataHook(token) }
        guard let value = metadata[token] else { throw InfisicalError.invalidScope }
        return value
    }
    func fetchSecrets(accessToken: String, environment: String, projectId: String) async throws -> [String: String] {
        try await fetchSecrets(accessToken: accessToken, environment: environment, projectId: projectId, secretPath: "/")
    }
    func fetchSecrets(accessToken: String, environment: String, projectId: String, secretPath: String) async throws -> [String: String] {
        reads.append(accessToken)
        if let fetchHook { return try await fetchHook(accessToken) }
        return values[accessToken] ?? [:]
    }
    func upsertSecret(accessToken: String, environment: String, key: String, value: String, projectId: String) async throws {
        try await upsertSecret(accessToken: accessToken, environment: environment, key: key, value: value, projectId: projectId, secretPath: "/")
    }
    func upsertSecret(accessToken: String, environment: String, key: String, value: String, projectId: String, secretPath: String) async throws {
        writes.append((accessToken, projectId, secretPath))
        try await writeHook?()
    }
}

@MainActor
private final class ScopedGate<Value> {
    let entered: XCTestExpectation
    var continuation: CheckedContinuation<Value, Error>?
    init(_ entered: XCTestExpectation) { self.entered = entered }
    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation = $0; entered.fulfill() }
    }
    func finish(_ result: Result<Value, Error>) { continuation?.resume(with: result); continuation = nil }
}

@MainActor
final class InfisicalServiceTokenTests: XCTestCase {
    private static let project = "00000000-1111-2222-3333-444444444444"
    private static let other = "11111111-2222-3333-4444-555555555555"
    private let client = ScopedInfisicalClient()
    private let cache = InfisicalStore()
    private var saved: InfisicalCredential?
    private var persistenceCount = 0
    private lazy var settings = InfisicalSettings(client: client, store: cache,
        credentialProvider: { [weak self] in self?.saved },
        credentialWriter: { [unowned self] in saved = $0; persistenceCount += 1 },
        credentialRemover: { [unowned self] in saved = nil })

    private func entry(_ token: String, path: String = "/settings", project: String = InfisicalServiceTokenTests.project,
                       reads: Bool = true, writes: Bool = false) -> InfisicalServiceToken {
        let entry = InfisicalServiceToken(projectId: project, secretPath: path, token: token, reads: reads, writes: writes)
        client.metadata[token] = .init(projectId: project, scopes: [.init(environment: "prod", secretPath: path)],
                                       permissions: Set((reads ? ["read"] : []) + (writes ? ["write"] : [])))
        return entry
    }
    private func configuration(_ entries: [InfisicalServiceToken], project: String = InfisicalServiceTokenTests.project,
                               path: String = "/settings") -> InfisicalCredential {
        InfisicalCredential(clientId: "", clientSecret: "", projectId: project,
                            mode: .serviceTokens, secretPath: path, serviceTokens: entries)
    }

    func testOptionalAndBackwardCompatibleCredentials() async throws {
        await settings.bootstrap()
        XCTAssertFalse(settings.isConfigured)
        XCTAssertTrue(client.reads.isEmpty)
        XCTAssertEqual(client.loginCount, 0)
        let legacy = try JSONDecoder().decode(InfisicalCredential.self,
            from: Data("{\"clientId\":\"synthetic\",\"clientSecret\":\"synthetic\"}".utf8))
        XCTAssertFalse(legacy.isComplete)
        XCTAssertEqual(legacy.effectiveMode, .machineIdentity)
        let candidate = configuration([entry("synthetic-read")])
        let decoded = try JSONDecoder().decode(InfisicalCredential.self, from: JSONEncoder().encode(candidate))
        XCTAssertTrue(decoded.isComplete)
        XCTAssertEqual(decoded.serviceTokens?.count, 1)
    }

    func testMultipleFoldersAndProjectsWithSeparateReadAndWriteTokens() async throws {
        let reader = entry("synthetic-settings")
        let writer = entry("synthetic-writer", reads: false, writes: true)
        let alerts = entry("synthetic-alerts", path: "/alerts", writes: true)
        let other = entry("synthetic-other", project: Self.other)
        client.values[reader.token] = [InfisicalKey.refreshInterval: "7"]
        client.values[alerts.token] = [InfisicalKey.alertThresholdPercent: "450"]
        client.values[other.token] = [InfisicalKey.refreshInterval: "99"]
        try await settings.saveConfiguration(configuration([reader, writer, alerts, other]))
        XCTAssertEqual(client.reads, [reader.token, alerts.token])
        XCTAssertEqual(client.loginCount, 0)
        XCTAssertEqual(cache.int(for: InfisicalKey.refreshInterval), 7)
        try await settings.set("8", forKey: InfisicalKey.refreshInterval)
        try await settings.set("500", forKey: InfisicalKey.alertThresholdPercent)
        try await settings.set("30", forKey: InfisicalKey.alertCooldownMinutes)
        XCTAssertEqual(client.writes.map { $0.0 }, [writer.token, alerts.token, writer.token])
        XCTAssertEqual(client.writes.map { $0.2 }, ["/settings", "/alerts", "/settings"])
        try await settings.saveConfiguration(configuration([reader, writer, alerts, other], project: Self.other))
        XCTAssertEqual(cache.int(for: InfisicalKey.refreshInterval), 99)
        XCTAssertNil(cache.int(for: InfisicalKey.alertThresholdPercent))
        XCTAssertEqual(settings.projectId, Self.other)
    }

    func testReadonlyNeverWritesAndMetadataIsCheckedAgainBeforeWrite() async throws {
        let reader = entry("synthetic-read")
        client.values[reader.token] = [InfisicalKey.refreshInterval: "7"]
        try await settings.saveConfiguration(configuration([reader]))
        do { try await settings.set("8", forKey: InfisicalKey.refreshInterval); XCTFail("Read-only") } catch {}
        XCTAssertTrue(client.writes.isEmpty)
        XCTAssertEqual(cache.int(for: InfisicalKey.refreshInterval), 7)
        let writer = entry("synthetic-write", reads: false, writes: true)
        try await settings.saveConfiguration(configuration([reader, writer]))
        client.metadata[writer.token]?.permissions = ["read"]
        do { try await settings.set("8", forKey: InfisicalKey.refreshInterval); XCTFail("Revoked write") } catch {}
        XCTAssertTrue(client.writes.isEmpty)
        XCTAssertEqual(cache.int(for: InfisicalKey.refreshInterval), 7)
    }

    func testScopeMismatchAndDuplicateKeysCannotReplaceWorkingConfiguration() async throws {
        let reader = entry("synthetic-read")
        client.values[reader.token] = [InfisicalKey.refreshInterval: "7"]
        try await settings.saveConfiguration(configuration([reader]))
        let before = settings.connectionGeneration
        let second = entry("synthetic-second", path: "/other")
        client.values[second.token] = [InfisicalKey.refreshInterval: "99"]
        do { try await settings.saveConfiguration(configuration([reader, second])); XCTFail("Ambiguous") } catch {}
        XCTAssertEqual(settings.connectionGeneration, before)
        XCTAssertEqual(cache.int(for: InfisicalKey.refreshInterval), 7)
        for variant in 0..<5 {
            var metadata = client.metadata[reader.token]!
            if variant == 0 { metadata.projectId = Self.other }
            if variant == 1 { metadata.scopes = [.init(environment: "prod", secretPath: "/different")] }
            if variant == 2 { metadata.scopes = [.init(environment: "dev", secretPath: reader.secretPath)] }
            if variant == 3 { metadata.scopes.append(.init(environment: "prod", secretPath: "/extra")) }
            if variant == 4 { metadata.permissions = [] }
            client.metadata[reader.token] = metadata
            let count = client.reads.count
            do { try await settings.saveConfiguration(configuration([reader])); XCTFail("Invalid metadata") } catch {}
            XCTAssertEqual(client.reads.count, count)
            XCTAssertEqual(settings.connectionGeneration, before)
            XCTAssertEqual(cache.int(for: InfisicalKey.refreshInterval), 7)
            client.metadata[reader.token] = .init(projectId: Self.project,
                scopes: [.init(environment: "prod", secretPath: reader.secretPath)], permissions: ["read"])
        }
        XCTAssertEqual(persistenceCount, 1)
    }

    func testOfflineRelaunchCannotGuessWriteFolder() async throws {
        let reader = entry("synthetic-read", writes: true)
        saved = configuration([reader])
        client.metadata[reader.token] = nil
        await settings.bootstrap()
        do { try await settings.set("8", forKey: InfisicalKey.refreshInterval); XCTFail("Unknown folder provenance") } catch {}
        XCTAssertTrue(client.writes.isEmpty)
        XCTAssertEqual(client.loginCount, 0)
    }

    func testRefreshFailureKeepsLastKnownGoodWithoutFallback() async throws {
        let reader = entry("synthetic-read")
        client.values[reader.token] = [InfisicalKey.refreshInterval: "7"]
        try await settings.saveConfiguration(configuration([reader]))
        client.metadata[reader.token] = nil
        await settings.refresh()
        XCTAssertEqual(cache.int(for: InfisicalKey.refreshInterval), 7)
        XCTAssertNotNil(settings.lastError)
        XCTAssertEqual(client.loginCount, 0)
        XCTAssertEqual(client.reads.count, 1)
    }

    func testClearInvalidatesInflightServiceTokenSave() async throws {
        let reader = entry("synthetic-read")
        let gate = ScopedGate<InfisicalTokenMetadata>(expectation(description: "Metadata entered"))
        client.metadataHook = { _ in try await gate.wait() }
        let pending = Task { try await settings.saveConfiguration(configuration([reader])) }
        await fulfillment(of: [gate.entered], timeout: 2)
        try settings.clearCredential()
        gate.finish(.success(client.metadata[reader.token]!))
        do { try await pending.value; XCTFail("Stale save") } catch {}
        XCTAssertFalse(settings.isConfigured)
        XCTAssertNil(saved)
        XCTAssertEqual(persistenceCount, 0)
        XCTAssertTrue(client.reads.isEmpty)
        XCTAssertEqual(cache.snapshot.projectId, InfisicalStore.localProjectId)
    }

    func testOldServiceTokenWriteCannotMutateNewMode() async throws {
        let reader = entry("synthetic-read", writes: true)
        client.values[reader.token] = [InfisicalKey.refreshInterval: "7"]
        try await settings.saveConfiguration(configuration([reader]))
        let gate = ScopedGate<Void>(expectation(description: "Write entered"))
        client.writeHook = { try await gate.wait() }
        let pending = Task { try await settings.set("99", forKey: InfisicalKey.refreshInterval) }
        await fulfillment(of: [gate.entered], timeout: 2)
        client.values["synthetic-mi"] = [InfisicalKey.refreshInterval: "11"]
        try await settings.saveCredential(clientId: "synthetic-id", clientSecret: "synthetic-secret", projectId: Self.project)
        gate.finish(.success(()))
        do { try await pending.value; XCTFail("Stale write") } catch {}
        XCTAssertEqual(cache.int(for: InfisicalKey.refreshInterval), 11)
        XCTAssertEqual(settings.authMode, .machineIdentity)
        XCTAssertNil(settings.lastError)
    }

    func testLateServiceRefreshCannotReplaceNewMachineIdentity() async throws {
        let reader = entry("synthetic-read")
        client.values[reader.token] = [InfisicalKey.refreshInterval: "7"]
        try await settings.saveConfiguration(configuration([reader]))
        let gate = ScopedGate<[String: String]>(expectation(description: "Read entered"))
        client.fetchHook = { token in
            if token == reader.token { return try await gate.wait() }
            return [InfisicalKey.refreshInterval: "11"]
        }
        let pending = Task { await settings.refresh() }
        await fulfillment(of: [gate.entered], timeout: 2)
        try await settings.saveCredential(clientId: "synthetic-id", clientSecret: "synthetic-secret", projectId: Self.project)
        gate.finish(.success([InfisicalKey.refreshInterval: "99"]))
        await pending.value
        XCTAssertEqual(cache.int(for: InfisicalKey.refreshInterval), 11)
        XCTAssertEqual(settings.authMode, .machineIdentity)
        XCTAssertNil(settings.lastError)
    }

    func testFolderSwitchResetsPersistedEffectiveSettings() async throws {
        let suite = "InfisicalServiceTokenTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let hog = HogStore(historyURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString),
            defaults: defaults, infisical: settings, startImmediately: false)
        let first = entry("synthetic-first")
        client.values[first.token] = [InfisicalKey.refreshInterval: "7", InfisicalKey.alertWebhookURL: "https://synthetic.invalid"]
        try await settings.saveConfiguration(configuration([first]))
        XCTAssertEqual(hog.refreshInterval, 7)
        let second = entry("synthetic-second", path: "/other")
        try await settings.saveConfiguration(configuration([second], path: "/other"))
        XCTAssertEqual(hog.refreshInterval, 5)
        XCTAssertEqual(hog.alertWebhookURL, "")
        XCTAssertEqual(defaults.string(forKey: HogStore.Key.alertWebhookURL), "")
        XCTAssertTrue(client.writes.isEmpty)
    }

    func testLegacyRetirementSurvivesMissingKeychainAndFailedFileUnlink() async throws {
        for action in ["save", "clear"] {
            let suite = "InfisicalLegacyMigrationTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let migration = InfisicalLegacyCredentialMigration.persistence(in: defaults)
            let legacy = InfisicalCredential(clientId: "synthetic-legacy-id", clientSecret: "synthetic-legacy-secret", projectId: Self.project)
            var secured: InfisicalCredential?
            var fileReads = 0
            func make() -> InfisicalSettings {
                let owner = InfisicalSettings(client: client, store: InfisicalStore(),
                    credentialWriter: { secured = $0 }, credentialRemover: { secured = nil },
                    legacyMigration: migration, legacyDraftReader: {
                        fileReads += 1
                        return legacy // Simulate a legacy file that cannot be unlinked.
                    })
                owner.keychainReader = { .init(credential: secured, terminal: true, absent: secured == nil) }
                return owner
            }
            let initial = make()
            await initial.bootstrap()
            XCTAssertFalse(initial.isConfigured)
            XCTAssertEqual(fileReads, 0, "Startup must not inspect legacy files")
            XCTAssertEqual(initial.editingCredential?.clientId, legacy.clientId)
            XCTAssertTrue(initial.hasCredentialDraft)
            XCTAssertEqual(fileReads, 1)
            XCTAssertEqual(client.loginCount, 0)
            XCTAssertFalse(migration.isRetired())
            if action == "save" {
                let reader = entry("synthetic-migration-reader")
                try await initial.saveConfiguration(configuration([reader]))
                XCTAssertEqual(secured?.effectiveMode, .serviceTokens)
            } else {
                try initial.clearCredential()
            }
            XCTAssertTrue(InfisicalLegacyCredentialMigration.persistence(in: UserDefaults(suiteName: suite)!).isRetired())
            secured = nil // Simulate later Keychain disappearance, not successful file deletion.
            let before = client.loginCount
            let relaunched = make()
            await relaunched.bootstrap()
            XCTAssertFalse(relaunched.isConfigured)
            XCTAssertNil(relaunched.editingCredential)
            XCTAssertEqual(fileReads, 1, "Retired credentials must never be read again")
            XCTAssertEqual(client.loginCount, before, "No legacy machine-identity fallback")
        }
    }

    func testFailedExplicitSaveDoesNotRetireLegacyDraft() async throws {
        var retired = false
        let reader = entry("synthetic-failed-migration")
        let owner = InfisicalSettings(client: client, store: InfisicalStore(), credentialProvider: { nil },
            credentialWriter: { _ in throw InfisicalError.credentialStorage }, credentialRemover: {},
            legacyMigration: .init(isRetired: { retired }, retire: { retired = true }))
        do { try await owner.saveConfiguration(configuration([reader])); XCTFail("Persistence must fail") } catch {}
        XCTAssertFalse(retired)
    }

    func testFileDraftNeverAuthenticatesUntilExplicitMachineIdentitySave() async throws {
        let legacy = InfisicalCredential(clientId: "synthetic-inherited-id", clientSecret: "synthetic-inherited-secret", projectId: Self.project)
        var secured: InfisicalCredential?
        var retired = false
        var fileReads = 0
        let owner = InfisicalSettings(client: client, store: cache,
            credentialWriter: { secured = $0 }, credentialRemover: { secured = nil },
            legacyMigration: .init(isRetired: { retired }, retire: { retired = true }),
            legacyDraftReader: { fileReads += 1; return legacy })
        owner.keychainReader = { .init(credential: secured, terminal: true, absent: secured == nil) }
        await owner.bootstrap()
        await owner.refreshIfDue()
        await owner.refresh() // The Sync Now path must remain inert too.
        XCTAssertFalse(owner.isConfigured)
        XCTAssertEqual(fileReads, 0)
        XCTAssertEqual(client.loginCount, 0)
        XCTAssertTrue(client.reads.isEmpty)
        let draft = try XCTUnwrap(owner.editingCredential)
        XCTAssertTrue(owner.hasCredentialDraft)
        XCTAssertEqual(fileReads, 1)
        await owner.refreshIfDue()
        await owner.refresh()
        XCTAssertEqual(client.loginCount, 0, "Opening the editor cannot activate a draft")
        try await owner.saveConfiguration(draft)
        XCTAssertEqual(secured?.mode, .machineIdentity)
        XCTAssertTrue(secured?.isOperational == true)
        XCTAssertTrue(owner.isConfigured)
        XCTAssertFalse(owner.hasCredentialDraft)
        XCTAssertTrue(retired)
        let restarted = InfisicalSettings(client: client, store: InfisicalStore(),
            credentialWriter: { _ in }, credentialRemover: {},
            legacyDraftReader: { XCTFail("Explicit Keychain connection must not inspect files"); return nil })
        restarted.keychainReader = { .init(credential: secured, terminal: true) }
        await restarted.bootstrap()
        XCTAssertTrue(restarted.isConfigured)
        XCTAssertEqual(client.loginCount, 2, "Only explicit save and the confirmed relaunch authenticate")
    }

    func testModelessKeychainIdentityIsOnlyAnEditorDraft() async throws {
        let inherited = InfisicalCredential(clientId: "synthetic-old-id", clientSecret: "synthetic-old-secret", projectId: Self.project)
        var secured: InfisicalCredential? = inherited
        let owner = InfisicalSettings(client: client, store: cache,
            credentialWriter: { secured = $0 }, credentialRemover: { secured = nil },
            legacyDraftReader: { XCTFail("A present Keychain item must not inspect legacy files"); return nil })
        owner.keychainReader = { .init(credential: secured, terminal: true) }
        await owner.bootstrap()
        await owner.refreshIfDue()
        await owner.refresh()
        XCTAssertFalse(owner.isConfigured)
        XCTAssertEqual(client.loginCount, 0)
        XCTAssertEqual(owner.editingCredential?.clientId, inherited.clientId)
        XCTAssertTrue(owner.hasCredentialDraft)
        try await owner.saveCredential(clientId: inherited.clientId, clientSecret: inherited.clientSecret, projectId: Self.project)
        XCTAssertEqual(secured?.mode, .machineIdentity)
        XCTAssertTrue(owner.isConfigured)
        XCTAssertEqual(client.loginCount, 1)
    }

    func testDraftFilesRequireDefinitiveKeychainAbsenceAndUnretiredState() async {
        for read in [KeychainCredentialRead(credential: nil, terminal: false),
                     KeychainCredentialRead(credential: nil, terminal: true, absent: false)] {
            var fileReads = 0
            let owner = InfisicalSettings(client: client, store: InfisicalStore(),
                credentialWriter: { _ in }, credentialRemover: {},
                legacyDraftReader: { fileReads += 1; return nil })
            owner.keychainReader = { read }
            await owner.bootstrap()
            XCTAssertNil(owner.editingCredential)
            await owner.refreshIfDue()
            XCTAssertEqual(fileReads, 0)
            XCTAssertEqual(client.loginCount, 0)
        }
        var fileReads = 0
        let retired = InfisicalSettings(client: client, store: InfisicalStore(),
            credentialWriter: { _ in }, credentialRemover: {},
            legacyMigration: .init(isRetired: { true }, retire: {}),
            legacyDraftReader: { fileReads += 1; return nil })
        retired.keychainReader = { .init(credential: nil, terminal: true, absent: true) }
        await retired.bootstrap()
        XCTAssertNil(retired.editingCredential)
        XCTAssertEqual(fileReads, 0)
    }

    func testEditorRechecksCachedAbsenceBeforeReadingLegacyFile() async {
        var read = KeychainCredentialRead(credential: nil, terminal: true, absent: true)
        var fileReads = 0
        let owner = InfisicalSettings(client: client, store: cache,
            credentialWriter: { _ in }, credentialRemover: {},
            legacyDraftReader: { fileReads += 1; return nil })
        owner.keychainReader = { read }
        await owner.bootstrap()
        read = .init(credential: nil, terminal: false) // Keychain locked after bootstrap.
        XCTAssertNil(owner.editingCredential)
        XCTAssertEqual(fileReads, 0)
        read = .init(credential: nil, terminal: true, absent: false) // Present but undecodable.
        XCTAssertNil(owner.editingCredential)
        XCTAssertEqual(fileReads, 0)
        read = .init(credential: nil, terminal: true, absent: true)
        XCTAssertNil(owner.editingCredential)
        XCTAssertEqual(fileReads, 1)
        XCTAssertEqual(client.loginCount, 0)
    }

    func testFailedDraftSavePreservesLocalSettingsAndUnconfirmedDraft() async throws {
        let draft = InfisicalCredential(clientId: "synthetic-old-id", clientSecret: "synthetic-old-secret", projectId: Self.project)
        var retired = false
        var persisted = 0
        let owner = InfisicalSettings(client: client, store: cache,
            credentialWriter: { _ in persisted += 1; throw InfisicalError.credentialStorage }, credentialRemover: {},
            legacyMigration: .init(isRetired: { retired }, retire: { retired = true }), legacyDraftReader: { draft })
        owner.keychainReader = { .init(credential: nil, terminal: true, absent: true) }
        await owner.bootstrap()
        cache.set("9", forKey: InfisicalKey.refreshInterval)
        let candidate = try XCTUnwrap(owner.editingCredential)
        do { try await owner.saveConfiguration(candidate); XCTFail("Keychain persistence failure") } catch {}
        XCTAssertFalse(owner.isConfigured)
        XCTAssertTrue(owner.hasCredentialDraft)
        XCTAssertFalse(retired)
        XCTAssertEqual(persisted, 1)
        XCTAssertEqual(cache.int(for: InfisicalKey.refreshInterval), 9)
        let before = client.loginCount
        await owner.refreshIfDue()
        await owner.refresh()
        XCTAssertEqual(client.loginCount, before, "A failed save must not activate inherited identity")
        XCTAssertNotNil(owner.editingCredential)
    }

    func testSameProjectFolderChangeHasDistinctCacheIdentity() async throws {
        let first = entry("synthetic-first")
        let second = entry("synthetic-second", path: "/other")
        client.values[first.token] = [InfisicalKey.refreshInterval: "7", InfisicalKey.alertWebhookURL: "https://synthetic.invalid"]
        try await settings.saveConfiguration(configuration([first]))
        let previous = cache.snapshot.projectId
        try await settings.saveConfiguration(configuration([second], path: "/other"))
        XCTAssertNotEqual(cache.snapshot.projectId, previous)
        XCTAssertEqual(cache.count, 0)
    }
}
