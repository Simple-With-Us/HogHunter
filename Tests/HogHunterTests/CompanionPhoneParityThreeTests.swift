import XCTest

@testable import HogHunter

// Phone parity, batch 3: storage category totals, the Standard cleanable line,
// custom script names, Maintain step toggles and thresholds, the temp file
// minimum, and Launch at Login.
//
// Nothing here runs the real script, SSH, or touches the real login items or
// cleaner settings.  Every store gets a stub launcher and an isolated
// UserDefaults suite, and the login item and temp file saver are injected.

// MARK: - Validation

final class CompanionMaintainSettingsValidatorTests: XCTestCase {
    private func validate(_ request: CompanionMaintainSettingsRequest) -> Result<CompanionMaintainSettingsValidator.Validated, CompanionSettingsRejection> {
        CompanionMaintainSettingsValidator.validate(request)
    }

    private func rejection(_ request: CompanionMaintainSettingsRequest) -> String? {
        if case .failure(let rejection) = validate(request) { return rejection.message }
        return nil
    }

    func testBuiltInStepsAreAccepted() throws {
        let ids = MaintainStore.catalog.map(\.id)
        let request = CompanionMaintainSettingsRequest(stepEnabled: Dictionary(uniqueKeysWithValues: ids.filter { $0 != CompanionMaintainLimits.remoteServerStepId }.map { ($0, false) }))
        let validated = try XCTUnwrap(try? validate(request).get())
        XCTAssertEqual(validated.stepEnabled.count, ids.count - 1)
    }

    func testACustomScriptKeyIsRefused() throws {
        for key in ["custom_cleanup", "maintain_entrypoints", "prune-docker.sh", "/Users/x/run.sh", "", "Npm_Cache", "npm_cache ", "../npm_cache"] {
            let message = try XCTUnwrap(rejection(CompanionMaintainSettingsRequest(stepEnabled: [key: true])), key)
            XCTAssertTrue(message.contains("Custom scripts"), message)
            XCTAssertTrue(message.contains("\u{00A0}"), message)
        }
    }

    func testOneBadKeyRejectsTheWholeChange() {
        let request = CompanionMaintainSettingsRequest(stepEnabled: ["npm_cache": false, "not_a_step": true], pm2LogsCapMB: 50)
        XCTAssertNotNil(rejection(request))
    }

    func testTheRemoteServerStepNeedsAnAcknowledgementToTurnOn() throws {
        let on = CompanionMaintainSettingsRequest(stepEnabled: [CompanionMaintainLimits.remoteServerStepId: true])
        let message = try XCTUnwrap(rejection(on))
        XCTAssertTrue(message.contains("confirmation"), message)
        var acknowledged = on
        acknowledged.acknowledgeRemoteServer = true
        XCTAssertNil(rejection(acknowledged))
        var no = on
        no.acknowledgeRemoteServer = false
        XCTAssertNotNil(rejection(no))
        // Turning it off never needs one.
        XCTAssertNil(rejection(CompanionMaintainSettingsRequest(stepEnabled: [CompanionMaintainLimits.remoteServerStepId: false])))
        // An acknowledgement for some other change does not stand in for it.
        let other = CompanionMaintainSettingsRequest(stepEnabled: [CompanionMaintainLimits.remoteServerStepId: true, "npm_cache": true], acknowledgeRemoteServer: nil)
        XCTAssertNotNil(rejection(other))
    }

    func testTheDiskThresholdKeepsTheMacsRangeAndStep() {
        for good in [30.0, 35, 80, 195, 200] {
            XCTAssertNil(rejection(CompanionMaintainSettingsRequest(lowFreeGiB: good)), "\(good)")
        }
        for bad in [0.0, 25, 29, 31, 82.5, 201, 205, -30, .nan, .infinity, -.infinity] {
            XCTAssertNotNil(rejection(CompanionMaintainSettingsRequest(lowFreeGiB: bad)), "\(bad)")
        }
    }

    func testThePm2CapKeepsTheMacsRangeAndStep() {
        for good in [10, 20, 50, 200] {
            XCTAssertNil(rejection(CompanionMaintainSettingsRequest(pm2LogsCapMB: good)), "\(good)")
        }
        for bad in [-10, 0, 5, 9, 15, 55, 201, 210, Int.max] {
            XCTAssertNotNil(rejection(CompanionMaintainSettingsRequest(pm2LogsCapMB: bad)), "\(bad)")
        }
    }

    func testTheWorktreeRetentionKeepsTheMacsRange() {
        for good in [1, 7, 90] {
            XCTAssertNil(rejection(CompanionMaintainSettingsRequest(worktreeRetireMinDays: good)), "\(good)")
        }
        for bad in [Int.min, -1, 0, 91, 365, Int.max] {
            XCTAssertNotNil(rejection(CompanionMaintainSettingsRequest(worktreeRetireMinDays: bad)), "\(bad)")
        }
    }

    func testTheMacsOwnControlsReadTheSharedBounds() {
        // The Mac's stored-value check and the phone's route read one place.
        XCTAssertEqual(CompanionMaintainLimits.worktreeRetireDaysRange, 1...90)
        XCTAssertEqual(CompanionMaintainLimits.lowFreeGiBRange, 30...200)
        XCTAssertEqual(CompanionMaintainLimits.pm2LogsCapMBRange, 10...200)
        XCTAssertEqual(TempFileSafetyPolicy.allowedHours, CompanionCleanLimits.tempFileHoursRange)
    }

    func testAnEmptyChangeIsEmpty() {
        XCTAssertTrue(CompanionMaintainSettingsRequest().isEmpty)
        XCTAssertTrue(CompanionMaintainSettingsRequest(stepEnabled: [:]).isEmpty)
        XCTAssertTrue(CompanionMaintainSettingsRequest(acknowledgeRemoteServer: true).isEmpty)
        XCTAssertFalse(CompanionMaintainSettingsRequest(pm2LogsCapMB: 50).isEmpty)
    }
}

final class CompanionCleanSettingsValidatorTests: XCTestCase {
    private func message(_ hours: Double?) -> String? {
        if case .failure(let rejection) = CompanionCleanSettingsValidator.validate(CompanionCleanSettingsRequest(tempFileMinimumHours: hours)) {
            return rejection.message
        }
        return nil
    }

    func testTheTempFileMinimumCannotGoBelowTheMacs() throws {
        for good in [1.0, 24, 72, 8_760] { XCTAssertNil(message(good), "\(good)") }
        for bad in [0.0, 0.5, -1, -72, 8_761, 24.5, .nan, .infinity, -.infinity] { XCTAssertNotNil(message(bad), "\(bad)") }
        XCTAssertNotNil(message(nil))
        let text = try XCTUnwrap(message(0))
        XCTAssertTrue(text.contains("1 to 8,760"), text)
    }

    func testTheRulesAreTheSettingsWindowsRules() {
        for hours in [0.0, 1, 24, 8_760, 8_761, 24.5] {
            let phone: Bool
            if case .success = CompanionCleanSettingsValidator.validate(CompanionCleanSettingsRequest(tempFileMinimumHours: hours)) { phone = true } else { phone = false }
            XCTAssertEqual(phone, TempFileSafetyPolicy.isValid(hours), "\(hours)")
        }
    }
}

final class CompanionLoginItemRequestTests: XCTestCase {
    func testTheLoginItemPassesThroughTheSettingsValidator() throws {
        let on = try CompanionSettingsValidator.validate(CompanionSettingsUpdateRequest(launchesAtLogin: true)).get()
        XCTAssertEqual(on.launchesAtLogin, true)
        let off = try CompanionSettingsValidator.validate(CompanionSettingsUpdateRequest(launchesAtLogin: false)).get()
        XCTAssertEqual(off.launchesAtLogin, false)
        let none = try CompanionSettingsValidator.validate(CompanionSettingsUpdateRequest(alertsEnabled: true)).get()
        XCTAssertNil(none.launchesAtLogin)
    }

    func testAChangeOfOnlyTheLoginItemIsNotEmpty() {
        XCTAssertFalse(CompanionSettingsUpdateRequest(launchesAtLogin: false).isEmpty)
        XCTAssertTrue(CompanionSettingsUpdateRequest().isEmpty)
    }
}

// MARK: - The routes

final class CompanionParityThreeRouteTests: XCTestCase {
    private let code = "ABCD2345"
    private var deviceToken = ""
    private let lan = CompanionPeer(key: "192.168.1.20", isTrusted: true)
    private let wan = CompanionPeer(key: "203.0.113.9", isTrusted: false)

    private func server(maintain: Bool = false, clean: Bool = false, edit: Bool = false) -> CompanionServer {
        let server = CompanionServer()
        server.updateToken(code)
        deviceToken = server.devices.issue(name: "Test iPhone").token
        server.allowRemoteMaintain = maintain
        server.allowRemoteClean = clean
        server.allowRemoteEdit = edit
        server.syncOnQueue {}
        return server
    }

    private func reply(_ server: CompanionServer, _ request: Data, from peer: CompanionPeer? = nil) -> (status: Int, body: Data)? {
        let disposition = server.syncOnQueue { server.disposition(for: request, peer: peer ?? lan) }
        guard case .reply(let data) = disposition else { return nil }
        return CompanionHTTP.parseResponse(data)
    }

    private func raw(path: String, method: String = "POST", token: String? = nil, body: String = "{}") -> Data {
        let lines = [
            "\(method) \(path) HTTP/1.1",
            "Host: hoghunter",
            "Authorization: Bearer \(token ?? deviceToken)",
            "Content-Type: application/json",
            "Content-Length: \(body.utf8.count)",
            "Connection: close",
            "",
            body,
        ]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private let maintainUpdate = CompanionMaintainSettingsRequest(pm2LogsCapMB: 50)
    private let cleanUpdate = CompanionCleanSettingsRequest(tempFileMinimumHours: 24)

    // Maintain

    func testMaintainSettingsAreRefusedUntilTheMaintainOptInIsOn() throws {
        let server = server(maintain: false, clean: true, edit: true)
        server.onRemoteMaintainSettings = { _ in XCTFail("must not reach the handler"); return (200, Data()) }
        let parsed = try XCTUnwrap(reply(server, CompanionHTTP.maintainSettingsRequest(token: deviceToken, update: maintainUpdate)))
        XCTAssertEqual(parsed.status, 403)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: parsed.body) as? [String: Any])
        XCTAssertTrue((json["error"] as? String ?? "").contains("Allow iPhone to Run Maintenance"))
    }

    func testMaintainSettingsNeedALocalNetworkAndAPhonesOwnToken() {
        let server = server(maintain: true)
        server.onRemoteMaintainSettings = { _ in XCTFail("must not reach the handler"); return (200, Data()) }
        XCTAssertEqual(reply(server, CompanionHTTP.maintainSettingsRequest(token: deviceToken, update: maintainUpdate), from: wan)?.status, 403)
        XCTAssertEqual(reply(server, CompanionHTTP.maintainSettingsRequest(token: code, update: maintainUpdate))?.status, 403)
        XCTAssertEqual(reply(server, CompanionHTTP.maintainSettingsRequest(token: "hh1_wrong", update: maintainUpdate))?.status, 401)
    }

    func testMaintainSettingsReachTheHandlerWhenAllowed() throws {
        let server = server(maintain: true)
        let seen = CompanionLocked<CompanionMaintainSettingsRequest?>(nil)
        server.onRemoteMaintainSettings = { seen.value = $0; return (200, Data(#"{"status":"ok"}"#.utf8)) }
        let update = CompanionMaintainSettingsRequest(stepEnabled: ["npm_cache": false], lowFreeGiB: 90, worktreeRetireMinDays: 10, pm2LogsCapMB: 60)
        XCTAssertEqual(reply(server, CompanionHTTP.maintainSettingsRequest(token: deviceToken, update: update))?.status, 200)
        XCTAssertEqual(seen.value, update)
    }

    func testMaintainSettingsRefuseBadShapes() {
        let server = server(maintain: true)
        server.onRemoteMaintainSettings = { _ in XCTFail("must not reach the handler"); return (200, Data()) }
        let path = CompanionService.maintainSettingsPath
        XCTAssertEqual(reply(server, raw(path: path, method: "GET"))?.status, 405)
        XCTAssertEqual(reply(server, raw(path: path, body: "{}"))?.status, 400)
        XCTAssertEqual(reply(server, raw(path: path, body: "not json"))?.status, 400)
        XCTAssertEqual(reply(server, raw(path: path, body: #"{"pm2LogsCapMB":"fifty"}"#))?.status, 400)
        XCTAssertEqual(reply(server, raw(path: path + "?pm2LogsCapMB=50", body: #"{"pm2LogsCapMB":50}"#))?.status, 400)
        XCTAssertEqual(reply(server, raw(path: path, body: #"{"acknowledgeRemoteServer":true}"#))?.status, 400)
    }

    // Clean

    func testCleanSettingsAreRefusedUntilTheCleanerOptInIsOn() throws {
        let server = server(maintain: true, clean: false, edit: true)
        server.allowRemoteQuit = true
        server.onRemoteCleanSettings = { _ in XCTFail("must not reach the handler"); return (200, Data()) }
        let parsed = try XCTUnwrap(reply(server, CompanionHTTP.cleanSettingsRequest(token: deviceToken, update: cleanUpdate)))
        XCTAssertEqual(parsed.status, 403)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: parsed.body) as? [String: Any])
        XCTAssertTrue((json["error"] as? String ?? "").contains("Allow iPhone to Run Disk Cleaner"))
    }

    func testCleanSettingsNeedALocalNetworkAndAPhonesOwnToken() {
        let server = server(clean: true)
        server.onRemoteCleanSettings = { _ in XCTFail("must not reach the handler"); return (200, Data()) }
        XCTAssertEqual(reply(server, CompanionHTTP.cleanSettingsRequest(token: deviceToken, update: cleanUpdate), from: wan)?.status, 403)
        XCTAssertEqual(reply(server, CompanionHTTP.cleanSettingsRequest(token: code, update: cleanUpdate))?.status, 403)
        XCTAssertEqual(reply(server, CompanionHTTP.cleanSettingsRequest(token: "hh1_wrong", update: cleanUpdate))?.status, 401)
    }

    func testCleanSettingsReachTheHandlerWhenAllowedAndTakeNothingElse() {
        let server = server(clean: true)
        let seen = CompanionLocked<CompanionCleanSettingsRequest?>(nil)
        server.onRemoteCleanSettings = { seen.value = $0; return (200, Data(#"{"status":"ok"}"#.utf8)) }
        XCTAssertEqual(reply(server, CompanionHTTP.cleanSettingsRequest(token: deviceToken, update: cleanUpdate))?.status, 200)
        XCTAssertEqual(seen.value, cleanUpdate)
        let path = CompanionService.cleanSettingsPath
        XCTAssertEqual(reply(server, raw(path: path, method: "GET"))?.status, 405)
        XCTAssertEqual(reply(server, raw(path: path, body: "{}"))?.status, 400)
        // A field that is not the temp file minimum, such as an exclusion, changes nothing.
        XCTAssertEqual(reply(server, raw(path: path, body: #"{"excludedPath":"/Users/jay"}"#))?.status, 400)
        XCTAssertEqual(reply(server, raw(path: path + "?tempFileMinimumHours=1", body: #"{"tempFileMinimumHours":1}"#))?.status, 400)
    }

    // Launch at Login

    func testLaunchAtLoginRidesTheSettingsRouteBehindItsOptIn() throws {
        let off = server(edit: false)
        off.onRemoteSettings = { _ in XCTFail("must not reach the handler"); return (200, Data()) }
        let update = CompanionSettingsUpdateRequest(launchesAtLogin: true)
        XCTAssertEqual(reply(off, CompanionHTTP.settingsRequest(token: deviceToken, update: update))?.status, 403)

        let on = server(edit: true)
        let seen = CompanionLocked<CompanionSettingsUpdateRequest?>(nil)
        on.onRemoteSettings = { seen.value = $0; return (200, Data(#"{"status":"ok"}"#.utf8)) }
        XCTAssertEqual(reply(on, CompanionHTTP.settingsRequest(token: deviceToken, update: update))?.status, 200)
        XCTAssertEqual(seen.value?.launchesAtLogin, true)
    }
}

// MARK: - The codec

final class CompanionParityThreeCodecTests: XCTestCase {
    func testAnOlderMacsSnapshotStillDecodes() throws {
        let storageJSON = #"{"freeBytes":1,"totalBytes":2,"usedBytes":1,"freeText":"a","totalText":"b","usedText":"c","usedPercent":50}"#
        let storage = try JSONDecoder().decode(CompanionStorageSummary.self, from: Data(storageJSON.utf8))
        XCTAssertNil(storage.categoryTotals)
        XCTAssertNil(storage.tempFileMinimumHours)
        XCTAssertNil(storage.standardCleanableText)

        let maintainJSON = #"{"health":"healthy","displayHealth":"On schedule","launchdLoaded":true,"isRunning":false}"#
        let maintain = try JSONDecoder().decode(CompanionMaintainStatus.self, from: Data(maintainJSON.utf8))
        XCTAssertNil(maintain.stepSettings)
        XCTAssertNil(maintain.tuning)
        XCTAssertNil(maintain.customScripts)

        let settingsJSON = #"{"refreshInterval":5,"alertsEnabled":true,"alertThresholdPercent":300,"alertSustainedMinutes":5,"webhookConfigured":false}"#
        let settings = try JSONDecoder().decode(CompanionSettingsSummary.self, from: Data(settingsJSON.utf8))
        XCTAssertNil(settings.launchesAtLogin)
    }

    func testTheNewFieldsRoundTrip() throws {
        var maintain = CompanionMaintainStatus(health: "healthy", displayHealth: "On schedule", launchdLoaded: true, isRunning: false)
        maintain.stepSettings = [CompanionMaintainStepSetting(stepId: "npm_cache", title: "Trim npm Download Cache", isEnabled: false)]
        maintain.tuning = CompanionMaintainTuning(lowFreeGiB: 80, worktreeRetireMinDays: 7, pm2LogsCapMB: 50)
        maintain.customScripts = [CompanionMaintainScript(name: "prune.sh", isEnabled: true, mode: "owned", scope: "local")]
        let decoded = try JSONDecoder().decode(CompanionMaintainStatus.self, from: JSONEncoder().encode(maintain))
        XCTAssertEqual(decoded, maintain)
    }

    func testARequestOmitsWhatItDoesNotChange() throws {
        let data = try JSONEncoder().encode(CompanionCleanSettingsRequest(tempFileMinimumHours: 24))
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"tempFileMinimumHours":24}"#)
        let maintain = try JSONEncoder().encode(CompanionMaintainSettingsRequest(pm2LogsCapMB: 50))
        XCTAssertEqual(String(data: maintain, encoding: .utf8), #"{"pm2LogsCapMB":50}"#)
    }
}

// MARK: - What the Mac sends

final class CompanionParityThreeBuilderTests: XCTestCase {
    private func app(_ name: String, _ slices: [(StorageCategory, UInt64)]) -> StorageUsage {
        StorageUsage(
            bundleId: "com.example.\(name)",
            name: name,
            path: "/Applications/\(name).app",
            isRunning: false,
            bundleBytes: 0,
            hiddenBytes: slices.reduce(0) { $0 + $1.1 },
            slices: slices.map { StorageSlice(category: $0.0, path: "/x", bytes: $0.1, approximate: false) },
            anyApproximate: false
        )
    }

    func testCategoryTotalsAreTheMacsOwnSumsLargestFirst() {
        let totals = CompanionSnapshotBuilder.categoryTotals(from: [
            app("A", [(.caches, 300), (.logs, 20)]),
            app("B", [(.caches, 200), (.containers, 900)]),
        ])
        XCTAssertEqual(totals.map(\.id), ["containers", "caches", "logs"])
        XCTAssertEqual(totals.map(\.bytes), [900, 500, 20])
        XCTAssertEqual(totals.first?.title, StorageCategory.containers.displayName)
        XCTAssertEqual(totals.first?.text, HogFormat.memory(900))
    }

    func testCategoryTotalsSumTheAppsTheMacShows() {
        let many = (0..<(StorageStore.displayedLimit + 5)).map { app("App\($0)", [(.caches, 10)]) }
        let totals = CompanionSnapshotBuilder.categoryTotals(from: many)
        XCTAssertEqual(totals.first?.bytes, UInt64(StorageStore.displayedLimit * 10))
    }

    func testCustomScriptsCarryNamesAndStateNeverPaths() throws {
        let entries = [
            MaintainScriptEntry(id: "s1", path: "/Users/jay/secret-project/prune.sh", mode: "OWNED", scope: "Local", owner: "jay@example.com", argv: ["--token", "hunter2"]),
            MaintainScriptEntry(id: "maintain_entrypoints", path: "/Users/jay/Code/HogHunter/scripts/maintain.py", mode: "observed", scope: "remote", owner: "", argv: nil),
        ]
        let scripts = CompanionMaintain.scripts(entries, isEnabled: { $0 == "s1" })
        XCTAssertEqual(scripts.map(\.name), ["prune.sh", "Hog Hunter Maintenance"])
        XCTAssertEqual(scripts.map(\.isEnabled), [true, false])
        XCTAssertEqual(scripts.map(\.mode), ["owned", "observed"])
        let json = String(data: try JSONEncoder().encode(scripts), encoding: .utf8) ?? ""
        for secret in ["secret-project", "/Users", "jay@example.com", "hunter2", "--token", "s1", "scripts/maintain.py"] {
            XCTAssertFalse(json.contains(secret), "\(secret) reached the phone: \(json)")
        }
    }

    func testAStatusWithSettingsExistsBeforeTheFirstRun() throws {
        let settings = CompanionMaintain.Settings(
            stepSettings: [CompanionMaintainStepSetting(stepId: "npm_cache", title: "Trim npm Download Cache", isEnabled: true)],
            tuning: CompanionMaintainTuning(lowFreeGiB: 80, worktreeRetireMinDays: 7, pm2LogsCapMB: 50),
            customScripts: []
        )
        XCTAssertNil(CompanionMaintain.status(from: nil, history: [], isRunning: false, includeSteps: false))
        let status = try XCTUnwrap(CompanionMaintain.status(from: nil, history: [], isRunning: false, includeSteps: true, settings: settings))
        XCTAssertEqual(status.health, "unknown")
        XCTAssertFalse(status.isRunning)
        XCTAssertEqual(status.tuning, settings.tuning)
    }

    func testStepSettingsFollowTheMacsOrderAndMarkTheRemoteStep() {
        let settings = CompanionMaintain.stepSettings(visible: MaintainStore.catalog, isEnabled: { $0 != "npm_cache" })
        XCTAssertEqual(settings.map(\.stepId), MaintainStore.catalog.map(\.id))
        XCTAssertEqual(settings.filter(\.isRemoteServer).map(\.stepId), [CompanionMaintainLimits.remoteServerStepId])
        XCTAssertEqual(settings.first { $0.stepId == "npm_cache" }?.isEnabled, false)
    }
}

// MARK: - The store

@MainActor
final class CompanionParityThreeStoreTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var support: URL!
    private var launched: CompanionLocked<[[String]]>!
    private var maintain: MaintainStore!
    private var store: HogStore!

    override func setUp() async throws {
        suite = "hoghunter.tests.parity3.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        support = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hh-parity3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let log = CompanionLocked<[[String]]>([])
        launched = log
        maintain = MaintainStore(supportDirectory: support, repoRoot: support) { arguments in
            log.value.append(arguments)
            return true
        }
        store = HogStore(historyURL: isolatedHistoryURL(), defaults: defaults, infisical: IsolatedInfisical.make(), maintain: maintain, startImmediately: false)
        store.remoteTempPolicy = { TempFileSafetyPolicy.load(from: self.defaults) }
        store.remoteExclusions = { CleanerExclusions() }
        store.remoteTempPolicySaver = { _ in XCTFail("a test must say it expects a save") }
        store.loginItemIsEnabled = { false }
        store.loginItemRegistrar = { _ in XCTFail("a test must say it expects a registration") }
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: support)
    }

    // Maintain settings

    func testAStepToggleGoesThroughTheMacsOwnCall() async throws {
        XCTAssertTrue(maintain.isStepEnabled("npm_cache"))
        let reply = store.performRemoteMaintainSettings(CompanionMaintainSettingsRequest(stepEnabled: ["npm_cache": false]))
        XCTAssertEqual(reply.status, 200)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(launched.value.first, ["--set-step", "npm_cache", "off"])
    }

    func testACustomScriptKeyChangesNothing() async throws {
        let reply = store.performRemoteMaintainSettings(CompanionMaintainSettingsRequest(stepEnabled: ["my_custom_script": true]))
        XCTAssertEqual(reply.status, 400)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(launched.value.isEmpty)
        XCTAssertNil(maintain.stepToggles["my_custom_script"])
    }

    func testABadFieldRejectsTheWholeChange() async throws {
        let reply = store.performRemoteMaintainSettings(CompanionMaintainSettingsRequest(stepEnabled: ["npm_cache": false], pm2LogsCapMB: 55))
        XCTAssertEqual(reply.status, 400)
        let body = try JSONDecoder().decode(CompanionSettingsUpdateResponse.self, from: reply.body)
        XCTAssertEqual(body.status, "rejected")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(launched.value.isEmpty)
        XCTAssertTrue(maintain.isStepEnabled("npm_cache"))
        XCTAssertEqual(maintain.pm2LogsCapMB, 50)
    }

    func testThresholdsAreSavedWhereTheMacSavesThem() async throws {
        let reply = store.performRemoteMaintainSettings(CompanionMaintainSettingsRequest(lowFreeGiB: 95, worktreeRetireMinDays: 14, pm2LogsCapMB: 80))
        XCTAssertEqual(reply.status, 200)
        try await Task.sleep(nanoseconds: 900_000_000)
        let reread = MaintainStore(supportDirectory: support, repoRoot: support) { _ in true }
        XCTAssertEqual(reread.lowFreeGiB, 95)
        XCTAssertEqual(reread.pm2LogsCapMB, 80)
        XCTAssertEqual(reread.worktreeRetireMinDays, 14)
    }

    func testTurningOnServerMaintenanceNeedsTheAcknowledgement() async throws {
        var request = CompanionMaintainSettingsRequest(stepEnabled: [CompanionMaintainLimits.remoteServerStepId: true])
        XCTAssertEqual(store.performRemoteMaintainSettings(request).status, 400)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(launched.value.isEmpty)
        request.acknowledgeRemoteServer = true
        XCTAssertEqual(store.performRemoteMaintainSettings(request).status, 200)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(launched.value.first, ["--set-step", CompanionMaintainLimits.remoteServerStepId, "on"])
    }

    func testTheSettingsReachOnlyAPhoneAllowedToRunTheMaintain() throws {
        store.allowRemoteMaintain = false
        var snapshots = store.companionSnapshots()
        XCTAssertNil(snapshots.plain.maintain?.stepSettings)
        XCTAssertNil(snapshots.detailed)

        store.allowRemoteMaintain = true
        snapshots = store.companionSnapshots()
        XCTAssertNil(snapshots.plain.maintain?.stepSettings, "the plain snapshot goes to the shared code")
        XCTAssertNil(snapshots.plain.maintain?.customScripts)
        let detailed = try XCTUnwrap(snapshots.detailed?.maintain)
        XCTAssertEqual(detailed.stepSettings?.map(\.stepId), maintain.visibleCatalog.map(\.id))
        XCTAssertEqual(detailed.tuning, CompanionMaintainTuning(lowFreeGiB: maintain.lowFreeGiB, worktreeRetireMinDays: maintain.worktreeRetireMinDays, pm2LogsCapMB: maintain.pm2LogsCapMB))
        XCTAssertNotNil(detailed.customScripts)
        // The remote server step stays out until a host is set, as on the Mac.
        XCTAssertFalse(detailed.stepSettings?.contains { $0.isRemoteServer } ?? true)
    }

    // Temp file minimum

    func testTheTempFileMinimumIsSavedThroughTheSettingsWindowsSaver() async throws {
        let saved = CompanionLocked<[Double]>([])
        store.remoteTempPolicySaver = { saved.value.append($0) }
        XCTAssertEqual(store.performRemoteCleanSettings(CompanionCleanSettingsRequest(tempFileMinimumHours: 24)).status, 200)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(saved.value, [24])
    }

    func testAnInvalidTempFileMinimumSavesNothing() async throws {
        for bad in [0.0, 0.5, -3, 8_761, 12.5, .nan] {
            XCTAssertEqual(store.performRemoteCleanSettings(CompanionCleanSettingsRequest(tempFileMinimumHours: bad)).status, 400, "\(bad)")
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        // The saver in setUp fails the test if it was called.
    }

    func testTheSnapshotCarriesTheTempFileMinimum() {
        TempFileSafetyPolicy.save(hours: 96, to: defaults)
        let storage = store.companionSnapshots().plain.storage
        XCTAssertEqual(storage?.tempFileMinimumHours, 96)
    }

    // Standard cleanable

    func testStandardCleanableComesFromACurrentStandardScan() async throws {
        XCTAssertNil(store.companionSnapshots().plain.storage?.standardCleanableText)
        store.remoteScanner = { tier, _, _, _ in CleanerFixtures.sampleReport(tier: tier) }
        XCTAssertEqual(store.beginRemoteCleanScan(CompanionCleanScanRequest(tier: "standard")).status, 202)
        for _ in 0..<150 {
            if case .ready = store.remoteScanState { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let storage = try XCTUnwrap(store.companionSnapshots().plain.storage)
        let bytes = try XCTUnwrap(storage.standardCleanableBytes)
        XCTAssertGreaterThan(bytes, 0)
        XCTAssertEqual(storage.standardCleanableText, HogFormat.memory(bytes) + " Cleanable")
        // An old scan is a guess, so it is not advertised.
        let later = Date().addingTimeInterval(CompanionCleanerReport.scanLifetime + 60)
        XCTAssertNil(store.companionSnapshots(now: later).plain.storage?.standardCleanableText)
    }

    func testAnExtremeScanIsNotAStandardNumber() async throws {
        store.remoteScanner = { tier, _, _, _ in CleanerFixtures.sampleReport(tier: tier) }
        XCTAssertEqual(store.beginRemoteCleanScan(CompanionCleanScanRequest(tier: "extreme", acknowledgedExtreme: true)).status, 202)
        for _ in 0..<150 {
            if case .ready = store.remoteScanState { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(store.companionSnapshots().plain.storage?.standardCleanableText)
    }

    // Launch at Login

    func testLaunchAtLoginIsSetToAStateNotFlipped() {
        let calls = CompanionLocked<[Bool]>([])
        var enabled = false
        store.loginItemIsEnabled = { enabled }
        store.loginItemRegistrar = { want in calls.value.append(want); enabled = want }
        store.applyRemoteSettings(try! CompanionSettingsValidator.validate(CompanionSettingsUpdateRequest(launchesAtLogin: true)).get())
        XCTAssertEqual(calls.value, [true])
        XCTAssertTrue(store.launchesAtLogin)
        // Asking for what the Mac already has does nothing.
        store.applyRemoteSettings(try! CompanionSettingsValidator.validate(CompanionSettingsUpdateRequest(launchesAtLogin: true)).get())
        XCTAssertEqual(calls.value, [true])
        store.applyRemoteSettings(try! CompanionSettingsValidator.validate(CompanionSettingsUpdateRequest(launchesAtLogin: false)).get())
        XCTAssertEqual(calls.value, [true, false])
        XCTAssertFalse(store.launchesAtLogin)
    }

    func testARefusedRegistrationLeavesTheOldStateShowing() {
        struct Refused: Error {}
        store.loginItemRegistrar = { _ in throw Refused() }
        store.applyRemoteSettings(try! CompanionSettingsValidator.validate(CompanionSettingsUpdateRequest(launchesAtLogin: true)).get())
        XCTAssertFalse(store.launchesAtLogin)
        XCTAssertNotNil(store.loginItemError)
        XCTAssertEqual(store.companionSnapshots().plain.settings?.launchesAtLogin, false)
    }

    func testTheSnapshotReportsLaunchAtLogin() {
        XCTAssertEqual(store.companionSnapshots().plain.settings?.launchesAtLogin, false)
    }
}

// MARK: - Copy

final class CompanionParityThreeCopyTests: XCTestCase {
    func testRefusalsKeepTheirGap() throws {
        let rejections: [String] = [
            CompanionMaintainSettingsValidator.validate(CompanionMaintainSettingsRequest(stepEnabled: ["x": true])),
            CompanionMaintainSettingsValidator.validate(CompanionMaintainSettingsRequest(stepEnabled: [CompanionMaintainLimits.remoteServerStepId: true])),
        ].compactMap { result -> String? in
            if case .failure(let rejection) = result { return rejection.message }
            return nil
        }
        XCTAssertEqual(rejections.count, 2)
        for text in rejections {
            XCTAssertTrue(text.contains("\u{00A0}"), text)
            XCTAssertFalse(text.contains(".  "), text)
        }
    }
}
