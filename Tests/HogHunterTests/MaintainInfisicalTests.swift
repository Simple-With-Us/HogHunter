import XCTest
@testable import HogHunter

/// The Maintain tab's step toggles and remote server host against an Infisical
/// that is configured.  Everything is stubbed: no network, no Keychain, no
/// real script.  The store is handed its own `InfisicalSettings` and cache, so
/// nothing here touches the app's shared instances.

/// A stub Infisical that serves `secrets` and records or refuses writes.
@MainActor
private final class MaintainInfisicalClient: InfisicalServing {
    var secrets: [String: String] = [:]
    var failWrites = false
    var written: [(key: String, value: String)] = []

    func login(clientId: String, clientSecret: String) async throws -> String { "synthetic-token" }

    func fetchSecrets(accessToken: String, environment: String, projectId: String) async throws -> [String: String] {
        secrets
    }

    func upsertSecret(accessToken: String, environment: String, key: String, value: String, projectId: String) async throws {
        if failWrites { throw InfisicalError.httpStatus(500, "") }
        written.append((key, value))
    }
}

@MainActor
private struct ConfiguredMaintain {
    let store: MaintainStore
    let infisical: InfisicalSettings
    let cache: InfisicalStore
    let client: MaintainInfisicalClient
    let launches: CompanionLocked<[[String]]>
}

@MainActor
final class MaintainInfisicalTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hoghunter-maintain-infisical-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A MaintainStore whose Infisical is configured (the stub answered a
    /// refresh) and whose `config.json` holds `jsonSteps`.
    private func makeConfiguredMaintain(
        secrets: [String: String],
        jsonSteps: [String: Bool] = [:]
    ) async throws -> ConfiguredMaintain {
        let directory = try temporaryDirectory()
        if !jsonSteps.isEmpty {
            let steps = jsonSteps.mapValues { ["enabled": $0] }
            let data = try JSONSerialization.data(withJSONObject: ["steps": steps])
            try data.write(to: directory.appendingPathComponent("config.json"))
        }

        let client = MaintainInfisicalClient()
        client.secrets = secrets
        let cache = InfisicalStore()
        let infisical = InfisicalSettings(
            client: client,
            store: cache,
            credentialProvider: {
                InfisicalCredential(clientId: "id", clientSecret: "secret", projectId: "00000000-1111-2222-3333-444444444444")
            }
        )
        await infisical.refresh()
        XCTAssertTrue(infisical.isConfigured)

        let launches = CompanionLocked<[[String]]>([])
        let store = MaintainStore(
            supportDirectory: directory,
            repoRoot: directory,
            launcher: { arguments in
                launches.value.append(arguments)
                return true
            },
            infisical: infisical,
            infisicalStore: cache
        )
        return ConfiguredMaintain(store: store, infisical: infisical, cache: cache, client: client, launches: launches)
    }

    // MARK: - Reading

    func testInfisicalOverridesTheLocalStepToggles() async throws {
        let key = InfisicalKey.maintainStepShutdownSimulators
        // The local config says on; Infisical says off.  Infisical wins.
        let overridden = try await makeConfiguredMaintain(
            secrets: [key: "false"],
            jsonSteps: ["shutdown_simulators": true, "xcode_derived_data": false]
        )
        XCTAssertEqual(overridden.store.stepToggles["shutdown_simulators"], false)
        // A step Infisical does not carry keeps the local value.
        XCTAssertEqual(overridden.store.stepToggles["xcode_derived_data"], false)
        // A step neither carries keeps its built-in default.
        XCTAssertEqual(overridden.store.stepToggles["npm_cache"], true)

        // Infisical on, local off: Infisical still wins.
        let enabled = try await makeConfiguredMaintain(
            secrets: [key: "true"],
            jsonSteps: ["shutdown_simulators": false]
        )
        XCTAssertEqual(enabled.store.stepToggles["shutdown_simulators"], true)
    }

    func testTheInfisicalCacheIsNotConsultedUntilTheSettingsAreConfigured() throws {
        let directory = try temporaryDirectory()
        let cache = InfisicalStore(initial: [InfisicalKey.maintainStepShutdownSimulators: "false"])
        let infisical = InfisicalSettings(client: MaintainInfisicalClient(), store: cache, credentialProvider: { nil })
        let store = MaintainStore(
            supportDirectory: directory,
            repoRoot: directory,
            launcher: { _ in true },
            infisical: infisical,
            infisicalStore: cache
        )
        XCTAssertFalse(infisical.isConfigured)
        // Defaults: shutdown_simulators is on.
        XCTAssertEqual(store.stepToggles["shutdown_simulators"], true)
    }

    // MARK: - Writing

    func testAStepToggleWritesThroughToInfisicalAndThenTheLauncher() async throws {
        let key = InfisicalKey.maintainStepShutdownSimulators
        let setup = try await makeConfiguredMaintain(secrets: [key: "true"])
        XCTAssertEqual(setup.store.stepToggles["shutdown_simulators"], true)

        setup.store.setStepEnabled("shutdown_simulators", enabled: false)
        for _ in 0..<200 where setup.launches.value.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }

        XCTAssertEqual(setup.client.written.map { $0.key }, [key])
        XCTAssertEqual(setup.client.written.map { $0.value }, ["false"])
        XCTAssertEqual(setup.launches.value, [["--set-step", "shutdown_simulators", "off"]])
        XCTAssertEqual(setup.cache.string(for: key), "false")
        XCTAssertEqual(setup.store.stepToggles["shutdown_simulators"], false)
        XCTAssertNil(setup.store.lastError)
    }

    func testAFailedInfisicalWriteIsAFailedStepSave() async throws {
        let key = InfisicalKey.maintainStepShutdownSimulators
        let setup = try await makeConfiguredMaintain(secrets: [key: "true"])
        setup.client.failWrites = true

        setup.store.setStepEnabled("shutdown_simulators", enabled: false)
        for _ in 0..<200 where setup.store.lastError == nil { try await Task.sleep(nanoseconds: 10_000_000) }

        // The owner is told, the toggle goes back to what Infisical still holds,
        // the cache is untouched, and the script was never asked to save it.
        let message = try XCTUnwrap(setup.store.lastError)
        XCTAssertTrue(message.contains("Could not save that step setting to Infisical"), message)
        XCTAssertTrue(message.contains("\u{00A0}"), message)
        XCTAssertFalse(message.contains(".  "), message)
        XCTAssertEqual(setup.store.stepToggles["shutdown_simulators"], true)
        XCTAssertEqual(setup.cache.string(for: key), "true")
        XCTAssertTrue(setup.client.written.isEmpty)
        XCTAssertTrue(setup.launches.value.isEmpty)
    }

    func testAFailedInfisicalWriteIsAFailedHostSave() async throws {
        let key = InfisicalKey.maintainCoolifySshHost
        let setup = try await makeConfiguredMaintain(secrets: [key: "old-host"])
        XCTAssertEqual(setup.store.coolifyHost, "old-host")
        setup.client.failWrites = true

        setup.store.setCoolifyHost("new-host")
        for _ in 0..<200 where setup.store.lastError == nil { try await Task.sleep(nanoseconds: 10_000_000) }

        let message = try XCTUnwrap(setup.store.lastError)
        XCTAssertTrue(message.contains("Could not save the remote server SSH host to Infisical"), message)
        XCTAssertEqual(setup.store.coolifyHost, "old-host")
        XCTAssertEqual(setup.cache.string(for: key), "old-host")
        XCTAssertTrue(setup.launches.value.isEmpty)
    }
}
