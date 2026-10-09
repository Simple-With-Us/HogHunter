import Network
import XCTest

@testable import HogHunter

// Phone parity, batch 2, PR A: request bodies, settings, Sample for 3 Seconds,
// bandwidth and the snapshot fields the phone reads.

// MARK: - Reading a whole request

final class CompanionRequestBodyTests: XCTestCase {
    private func request(body: String, declared: Int? = nil) -> Data {
        let length = declared ?? body.utf8.count
        let head = "POST /v1/settings HTTP/1.1\r\nHost: hoghunter\r\nContent-Length: \(length)\r\n\r\n"
        return Data((head + body).utf8)
    }

    func testAHeaderOnlyRequestIsCompleteAtTheBlankLine() {
        XCTAssertEqual(CompanionHTTP.completeness(of: CompanionHTTP.request(token: "ABCD2345")), .complete)
    }

    func testARequestWithoutTheBlankLineWaitsForMore() {
        XCTAssertEqual(CompanionHTTP.completeness(of: Data("GET /v1/snapshot HTTP/1.1\r\nHost: x".utf8)), .needsMore)
    }

    func testABodyThatHasNotArrivedYetIsNotComplete() {
        let whole = request(body: #"{"alertsEnabled":true}"#)
        let headersOnly = whole.prefix(upTo: whole.range(of: Data("\r\n\r\n".utf8))!.upperBound)
        XCTAssertEqual(CompanionHTTP.completeness(of: Data(headersOnly)), .needsMore)
        XCTAssertEqual(CompanionHTTP.completeness(of: whole.prefix(whole.count - 3)), .needsMore)
        XCTAssertEqual(CompanionHTTP.completeness(of: whole), .complete)
    }

    func testAZeroOrUnparseableLengthIsCompleteAtTheBlankLine() {
        XCTAssertEqual(CompanionHTTP.completeness(of: Data("POST /v1/quit HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8)), .complete)
        XCTAssertEqual(CompanionHTTP.completeness(of: Data("POST /v1/quit HTTP/1.1\r\nContent-Length: lots\r\n\r\n".utf8)), .complete)
    }

    func testABodyLargerThanTheCapIsTooLargeBeforeItIsRead() {
        let declared = CompanionHTTP.maxBodyBytes + 1
        XCTAssertEqual(CompanionHTTP.completeness(of: request(body: "{}", declared: declared)), .tooLarge)
    }

    func testAHeadThatNeverEndsIsTooLarge() {
        let endless = Data(repeating: UInt8(ascii: "a"), count: CompanionHTTP.maxHeadBytes)
        XCTAssertEqual(CompanionHTTP.completeness(of: endless), .tooLarge)
    }

    func testTheBodyIsCutToContentLength() {
        let data = request(body: #"{"a":1}EXTRA"#, declared: 7)
        XCTAssertEqual(String(data: CompanionHTTP.bodyData(of: data), encoding: .utf8), #"{"a":1}"#)
        XCTAssertTrue(CompanionHTTP.bodyData(of: Data("GET / HTTP/1.1\r\n\r\n".utf8)).isEmpty)
    }

    func testTheTooLargeReplyKeepsItsGapAndStatus() throws {
        let parsed = try XCTUnwrap(CompanionHTTP.parseResponse(CompanionHTTP.payloadTooLargeReply()))
        XCTAssertEqual(parsed.status, 413)
        XCTAssertEqual(CompanionHTTP.reason(for: 413), "Payload Too Large")
    }

    /// The worst-first constraint of batch 2: a body that arrives in a later
    /// TCP segment than its headers must still reach the handler.  This opens
    /// a real listener and sends the two halves a moment apart.
    func testABodyThatArrivesInALaterSegmentStillReachesTheHandler() throws {
        let code = "ABCD2345"
        let server = CompanionServer()
        server.updateToken(code)
        let token = server.devices.issue(name: "Test iPhone").token
        server.allowRemoteEdit = true
        let seen = CompanionLocked<CompanionSettingsUpdateRequest?>(nil)
        server.onRemoteSettings = { update in
            seen.value = update
            return (200, Data(#"{"status":"ok"}"#.utf8))
        }
        let listening = expectation(description: "listening")
        let port = CompanionLocked<UInt16>(0)
        server.start(name: "test", peerID: "test", token: code, advertise: false, preferredPort: nil, loopbackOnly: true) { status in
            if status.hasPrefix("Sharing on port "), let value = UInt16(status.dropFirst("Sharing on port ".count)) {
                port.value = value
                listening.fulfill()
            }
        }
        wait(for: [listening], timeout: 5)
        defer { server.stop() }

        let whole = CompanionHTTP.settingsRequest(token: token, update: CompanionSettingsUpdateRequest(alertThresholdPercent: 450, webhookURL: "https://hooks.example.com/a/b"))
        let split = try XCTUnwrap(whole.range(of: Data("\r\n\r\n".utf8))).upperBound
        let queue = DispatchQueue(label: "hoghunter.tests.splitwrite")
        let client = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(NWEndpoint.Port(rawValue: port.value)), using: .tcp)
        let answered = expectation(description: "answered")
        let reply = CompanionLocked<Data>(Data())
        client.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            client.send(content: whole.prefix(split), completion: .contentProcessed { _ in
                queue.asyncAfter(deadline: .now() + 0.4) {
                    client.send(content: whole.suffix(from: split), completion: .contentProcessed { _ in })
                }
            })
            func read() {
                client.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { data, _, done, error in
                    if let data { reply.value.append(data) }
                    if CompanionHTTP.parseResponse(reply.value) != nil || done || error != nil {
                        answered.fulfill()
                    } else {
                        read()
                    }
                }
            }
            read()
        }
        client.start(queue: queue)
        wait(for: [answered], timeout: 10)
        client.cancel()

        XCTAssertEqual(CompanionHTTP.parseResponse(reply.value)?.status, 200)
        XCTAssertEqual(seen.value?.alertThresholdPercent, 450)
        XCTAssertEqual(seen.value?.webhookURL, "https://hooks.example.com/a/b")
    }
}

// MARK: - Settings

final class CompanionSettingsValidatorTests: XCTestCase {
    private func validate(_ request: CompanionSettingsUpdateRequest) -> Result<CompanionSettingsValidator.Validated, CompanionSettingsRejection> {
        CompanionSettingsValidator.validate(request)
    }

    func testEveryValueThePhoneOffersIsAccepted() throws {
        for interval in CompanionSettingsLimits.refreshIntervals {
            XCTAssertEqual(try validate(.init(refreshInterval: interval)).get().refreshInterval, interval)
        }
        for threshold in stride(from: 100.0, through: 1000.0, by: 50.0) {
            XCTAssertEqual(try validate(.init(alertThresholdPercent: threshold)).get().alertThresholdPercent, threshold)
        }
        for minutes in 1...30 {
            XCTAssertEqual(try validate(.init(alertSustainedMinutes: minutes)).get().alertSustainedMinutes, minutes)
        }
        XCTAssertEqual(try validate(.init(alertsEnabled: true)).get().alertsEnabled, true)
        XCTAssertTrue(try validate(.init(testWebhook: true)).get().testWebhook)
    }

    func testValuesOutsideWhatTheMacOffersAreRefused() {
        let bad: [CompanionSettingsUpdateRequest] = [
            .init(refreshInterval: 0), .init(refreshInterval: 1), .init(refreshInterval: 7), .init(refreshInterval: 3600),
            .init(refreshInterval: .nan),
            .init(alertThresholdPercent: 50), .init(alertThresholdPercent: 125), .init(alertThresholdPercent: 1050),
            .init(alertThresholdPercent: .infinity), .init(alertThresholdPercent: .nan), .init(alertThresholdPercent: -300),
            .init(alertSustainedMinutes: 0), .init(alertSustainedMinutes: 31), .init(alertSustainedMinutes: -5),
        ]
        for request in bad {
            guard case .failure = validate(request) else { return XCTFail("accepted \(request)") }
        }
    }

    func testOneBadFieldRejectsTheWholeChange() {
        let mixed = CompanionSettingsUpdateRequest(refreshInterval: 5, alertsEnabled: true, alertSustainedMinutes: 99)
        guard case .failure = validate(mixed) else { return XCTFail("a half-valid change must not be applied") }
    }

    func testTheWebhookMustBeHttpsWithAHost() throws {
        XCTAssertEqual(try validate(.init(webhookURL: "https://hooks.slack.com/services/T0/B0/xyz")).get().webhookURL, "https://hooks.slack.com/services/T0/B0/xyz")
        XCTAssertEqual(try validate(.init(webhookURL: "  https://example.com/hook \n")).get().webhookURL, "https://example.com/hook")
        XCTAssertEqual(try validate(.init(webhookURL: "")).get().webhookURL, "", "an empty address clears the webhook")
        XCTAssertEqual(try validate(.init(webhookURL: "   ")).get().webhookURL, "")
        for bad in ["http://example.com/hook", "ftp://example.com", "file:///etc/passwd", "javascript:alert(1)", "not a url", "https://", "example.com/hook", String(repeating: "a", count: 3_000)] {
            guard case .failure = validate(.init(webhookURL: bad)) else { return XCTFail("accepted webhook \(bad)") }
        }
    }

    func testSavingAWebhookAndTestingItAreSeparateRequests() {
        guard case .failure(let rejection) = validate(.init(webhookURL: "https://hooks.example.com/x", testWebhook: true)) else {
            return XCTFail("a request that sets a URL and tests it at once makes the Mac a probe of any https host")
        }
        XCTAssertTrue(rejection.message.contains("Save the webhook first"))
        XCTAssertNoThrow(try validate(.init(testWebhook: true)).get())
    }

    func testAnUppercaseSchemeIsStoredInTheFormTheAlertSenderExpects() throws {
        XCTAssertEqual(try validate(.init(webhookURL: "HTTPS://Hooks.Example.com/Path")).get().webhookURL, "https://Hooks.Example.com/Path")
        let stored = try XCTUnwrap(URL(string: try validate(.init(webhookURL: "HtTpS://example.com/x")).get().webhookURL ?? ""))
        XCTAssertEqual(stored.scheme, "https", "Alerts compares the scheme case-sensitively")
    }

    func testAnAbsentWebhookLeavesTheStoredOneAlone() throws {
        XCTAssertNil(try validate(.init(alertsEnabled: false)).get().webhookURL)
    }

    func testTheRefusalsKeepTheirGap() {
        guard case .failure(let rejection) = validate(.init(webhookURL: "http://example.com")) else { return XCTFail() }
        XCTAssertTrue(rejection.message.contains("\u{00A0}"))
        XCTAssertFalse(rejection.message.contains(".  "))
    }

    func testAnEmptyUpdateIsEmpty() {
        XCTAssertTrue(CompanionSettingsUpdateRequest().isEmpty)
        XCTAssertTrue(CompanionSettingsUpdateRequest(testWebhook: false).isEmpty)
        XCTAssertFalse(CompanionSettingsUpdateRequest(testWebhook: true).isEmpty)
        XCTAssertFalse(CompanionSettingsUpdateRequest(webhookURL: "").isEmpty, "clearing the webhook is a change")
    }
}

/// A settings source that cannot reach the owner's real Infisical project.
/// The test host is the real app, and `InfisicalSettings.shared` may hold the
/// owner's Keychain credential, so a store that writes a setting through it
/// would change the real project.
@MainActor
enum IsolatedInfisical {
    static func make() -> InfisicalSettings {
        InfisicalSettings(store: InfisicalStore(), credentialProvider: { nil })
    }
}

final class CompanionSettingsRouteTests: XCTestCase {
    private let code = "ABCD2345"
    private var deviceToken = ""
    private let lan = CompanionPeer(key: "192.168.1.20", isTrusted: true)
    private let wan = CompanionPeer(key: "203.0.113.9", isTrusted: false)

    private func server(edit: Bool) -> CompanionServer {
        let server = CompanionServer()
        server.updateToken(code)
        deviceToken = server.devices.issue(name: "Test iPhone").token
        server.allowRemoteEdit = edit
        server.syncOnQueue {}
        return server
    }

    private func status(_ server: CompanionServer, _ request: Data, from peer: CompanionPeer? = nil) -> Int? {
        let disposition = server.syncOnQueue { server.disposition(for: request, peer: peer ?? lan) }
        guard case .reply(let data) = disposition else { return nil }
        return CompanionHTTP.parseResponse(data)?.status
    }

    private func settingsRequest(_ update: CompanionSettingsUpdateRequest, token: String? = nil) -> Data {
        CompanionHTTP.settingsRequest(token: token ?? deviceToken, update: update)
    }

    func testSettingsAreRefusedUntilTheOwnerAllowsEdits() throws {
        let server = server(edit: false)
        server.onRemoteSettings = { _ in XCTFail("must not reach the handler"); return (200, Data()) }
        let disposition = server.syncOnQueue { server.disposition(for: settingsRequest(.init(alertsEnabled: true)), peer: lan) }
        guard case .reply(let data) = disposition else { return XCTFail("expected an inline refusal") }
        let parsed = try XCTUnwrap(CompanionHTTP.parseResponse(data))
        XCTAssertEqual(parsed.status, 403)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: parsed.body) as? [String: String])
        XCTAssertTrue(json["error"]?.contains("Allow iPhone to Change Exclusions & View") ?? false)
    }

    func testSettingsAreRefusedFromAnUntrustedAddress() {
        let server = server(edit: true)
        server.onRemoteSettings = { _ in XCTFail("must not reach the handler"); return (200, Data()) }
        XCTAssertEqual(status(server, settingsRequest(.init(alertsEnabled: true)), from: wan), 403)
    }

    func testSettingsAreRefusedWithTheSharedCode() {
        let server = server(edit: true)
        server.onRemoteSettings = { _ in XCTFail("must not reach the handler"); return (200, Data()) }
        XCTAssertEqual(status(server, settingsRequest(.init(alertsEnabled: true), token: code)), 403)
    }

    func testSettingsAreRefusedWithAWrongToken() {
        let server = server(edit: true)
        server.onRemoteSettings = { _ in XCTFail("must not reach the handler"); return (200, Data()) }
        XCTAssertEqual(status(server, settingsRequest(.init(alertsEnabled: true), token: "hh1_wrong")), 401)
    }

    func testSettingsReachTheHandlerOnceAllowed() {
        let server = server(edit: true)
        let received = CompanionLocked<CompanionSettingsUpdateRequest?>(nil)
        server.onRemoteSettings = { update in received.value = update; return (200, Data("{}".utf8)) }
        let update = CompanionSettingsUpdateRequest(refreshInterval: 5, alertsEnabled: true, alertThresholdPercent: 400, alertSustainedMinutes: 10, webhookURL: "https://example.com/h", testWebhook: true)
        XCTAssertEqual(status(server, settingsRequest(update)), 200)
        XCTAssertEqual(received.value, update)
    }

    func testAnUnreadableOrEmptyBodyNeverReachesTheHandler() {
        let server = server(edit: true)
        server.onRemoteSettings = { _ in XCTFail("must not reach the handler"); return (200, Data()) }
        XCTAssertEqual(status(server, settingsRequest(.init())), 400, "an empty change")
        var garbled = settingsRequest(.init(alertsEnabled: true))
        garbled.replaceSubrange(garbled.range(of: Data("{".utf8))!, with: Data("[".utf8))
        XCTAssertEqual(status(server, garbled), 400)
    }

    func testTheWebhookTravelsInTheBodyNotTheQuery() throws {
        let request = settingsRequest(.init(webhookURL: "https://hooks.example.com/secret-path"))
        let text = try XCTUnwrap(String(data: request, encoding: .utf8))
        let requestLine = try XCTUnwrap(text.components(separatedBy: "\r\n").first)
        XCTAssertFalse(requestLine.contains("secret-path"))
        XCTAssertFalse(requestLine.contains("?"))
        XCTAssertTrue(text.contains("Content-Length: "))
    }

    func testTheOptInAlsoGatesTheEditRefusalWording() throws {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: CompanionServer.editRefusal.body) as? [String: String])
        XCTAssertTrue(body["error"]?.contains("Mac settings") ?? false)
    }

    // MARK: The store side

    @MainActor
    func testAppliedSettingsGoThroughTheSamePropertiesSettingsUses() {
        let suite = "hoghunter.tests.remotesettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HogStore(defaults: defaults, infisical: IsolatedInfisical.make(), startImmediately: false)

        store.applyRemoteSettings(.init(refreshInterval: 10, alertsEnabled: nil, alertThresholdPercent: 450, alertSustainedMinutes: 12, webhookURL: "https://hooks.example.com/x", testWebhook: false))

        XCTAssertEqual(store.refreshInterval, 10)
        XCTAssertEqual(store.alertThresholdPercent, 450)
        XCTAssertEqual(store.alertSustainedMinutes, 12)
        XCTAssertEqual(store.alertWebhookURL, "https://hooks.example.com/x")
        XCTAssertEqual(store.alerts.webhookURL, "https://hooks.example.com/x")
        XCTAssertEqual(defaults.double(forKey: HogStore.Key.refreshInterval), 10)
        XCTAssertEqual(defaults.string(forKey: HogStore.Key.alertWebhookURL), "https://hooks.example.com/x")

        store.applyRemoteSettings(.init(refreshInterval: nil, alertsEnabled: nil, alertThresholdPercent: nil, alertSustainedMinutes: nil, webhookURL: "", testWebhook: false))
        XCTAssertEqual(store.alertWebhookURL, "", "an empty address clears the webhook")
    }

    @MainActor
    func testATestWebhookWithNothingToSendToIsRefusedBeforeItQueuesAnything() throws {
        let suite = "hoghunter.tests.remotesettings.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HogStore(defaults: defaults, infisical: IsolatedInfisical.make(), startImmediately: false)

        let refused = store.performRemoteSettings(.init(testWebhook: true))
        XCTAssertEqual(refused.status, 400)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: refused.body) as? [String: Any])
        XCTAssertTrue((json["error"] as? String)?.contains("No webhook is set.") ?? false)

        // Saving a webhook and testing it are separate requests.
        let combined = store.performRemoteSettings(.init(webhookURL: "https://hooks.invalid/x", testWebhook: true))
        XCTAssertEqual(combined.status, 400)

        // With a webhook set, a test goes through once, and not again at once.
        // `.invalid` never resolves, so the test message goes nowhere.
        store.alertWebhookURL = "https://hooks.invalid/x"
        XCTAssertEqual(store.performRemoteSettings(.init(testWebhook: true)).status, 200)
        let tooSoon = store.performRemoteSettings(.init(testWebhook: true))
        XCTAssertEqual(tooSoon.status, 429)
        let waitBody = try XCTUnwrap(JSONSerialization.jsonObject(with: tooSoon.body) as? [String: Any])
        XCTAssertTrue((waitBody["error"] as? String)?.contains("\u{00A0}") ?? false)
    }

    @MainActor
    func testABadValueIsRefusedWithAReasonAndAppliesNothing() throws {
        let suite = "hoghunter.tests.remotesettings.bad.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HogStore(defaults: defaults, infisical: IsolatedInfisical.make(), startImmediately: false)

        let refused = store.performRemoteSettings(.init(refreshInterval: 7))
        XCTAssertEqual(refused.status, 400)
        let decoded = try JSONDecoder().decode(CompanionSettingsUpdateResponse.self, from: refused.body)
        XCTAssertEqual(decoded.status, "rejected")
        XCTAssertNotNil(decoded.error)
        XCTAssertEqual(store.refreshInterval, 3)
    }
}

// MARK: - What the snapshot carries

final class CompanionSnapshotParityTwoTests: XCTestCase {
    func testTheSettingsSummaryNeverCarriesTheWebhookUrl() throws {
        let secret = "https://hooks.slack.com/services/T0AAAA/B0BBBB/s3cr3tt0k3n"
        let summary = CompanionSnapshotBuilder.settingsSummary(
            refreshInterval: 3, alertsEnabled: true, alertThresholdPercent: 300, alertSustainedMinutes: 5,
            webhookURL: secret, webhookStatus: "Failed: could not reach \(secret)", notificationsDenied: false
        )
        XCTAssertTrue(summary.webhookConfigured)
        XCTAssertEqual(summary.webhookHost, "…slack.com")
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(summary), encoding: .utf8))
        XCTAssertFalse(json.contains("s3cr3tt0k3n"), json)
        XCTAssertFalse(json.contains("/services/"), json)
        XCTAssertTrue(summary.webhookStatus?.contains("the webhook") ?? false)
    }

    func testOnlyTheLastTwoLabelsOfTheHostAreShown() {
        for (host, shown) in [("hooks.slack.com", "…slack.com"), ("abc123def.m.pipedream.net", "…pipedream.net"), ("discord.com", "discord.com"), ("localhost", "localhost")] {
            let summary = CompanionSnapshotBuilder.settingsSummary(
                refreshInterval: 3, alertsEnabled: true, alertThresholdPercent: 300, alertSustainedMinutes: 5,
                webhookURL: "https://\(host)/secret", webhookStatus: nil, notificationsDenied: false
            )
            XCTAssertEqual(summary.webhookHost, shown)
        }
    }

    func testNoWebhookReadsAsNotConfigured() {
        let summary = CompanionSnapshotBuilder.settingsSummary(
            refreshInterval: 3, alertsEnabled: false, alertThresholdPercent: 300, alertSustainedMinutes: 5,
            webhookURL: "  ", webhookStatus: nil, notificationsDenied: false
        )
        XCTAssertFalse(summary.webhookConfigured)
        XCTAssertNil(summary.webhookHost)
    }

    func testBandwidthUsesTheMacsOwnWords() {
        let measured = BandwidthReading(downBytesPerSecond: 2_411_520, upBytesPerSecond: 183_296, windowSeconds: 25, isMeasured: true)
        let peaks = NetworkPeaks(peakDownBytesPerSecond: 48_234_496, peakUpBytesPerSecond: 6_291_456, peakAt: Date(timeIntervalSince1970: 1_800_000_000), totalDownBytes: 1, totalUpBytes: 1, sampledSeconds: 3_600 * 5 + 120, hasSamples: true)
        let bandwidth = CompanionSnapshotBuilder.bandwidth(reading: measured, peaks: peaks, error: nil)
        XCTAssertTrue(bandwidth.isMeasured)
        XCTAssertEqual(bandwidth.downText, HogFormat.rate(2_411_520))
        XCTAssertEqual(bandwidth.peakUpText, HogFormat.rate(6_291_456))
        XCTAssertEqual(bandwidth.nowFootnote, "Last 25 s")
        XCTAssertEqual(bandwidth.peakFootnote, "Sampled 5h 2m")
        XCTAssertTrue(bandwidth.peakHelp.hasPrefix("The fastest sustained rate in the last 24 hours, reached at "))
    }

    func testBeforeAnyMeasurementItSaysSo() {
        let bandwidth = CompanionSnapshotBuilder.bandwidth(reading: .pending, peaks: .empty, error: "Could not read the network interface counters.")
        XCTAssertFalse(bandwidth.isMeasured)
        XCTAssertEqual(bandwidth.nowFootnote, "Measuring…")
        XCTAssertEqual(bandwidth.peakFootnote, "No History Yet")
        XCTAssertEqual(bandwidth.peakHelp, "The fastest sustained download or upload seen in the last 24 hours.")
        XCTAssertEqual(bandwidth.error, "Could not read the network interface counters.")
    }

    func testTheSnapshotCarriesTheNewFieldsAndAnOlderMacOmitsThem() throws {
        var pulse = MachinePulse.empty
        pulse.coreCount = 10
        let bandwidth = CompanionSnapshotBuilder.bandwidth(reading: .pending, peaks: .empty, error: nil)
        let snapshot = CompanionSnapshotBuilder.make(
            hostName: "test", sampledAt: Date(), hasBaseline: true,
            window: .now, grouping: .apps, scale: .machineShare, pulse: pulse, rows: [],
            bandwidth: bandwidth, cpuHistory: [10, 20, 30], settings: nil
        )
        let decoded = try CompanionJSON.decode(CompanionJSON.encode(snapshot))
        XCTAssertEqual(decoded.pulse.coreCount, 10)
        XCTAssertEqual(decoded.cpuHistory, [10, 20, 30])
        XCTAssertEqual(decoded.bandwidth, bandwidth)
        XCTAssertEqual(decoded.cpuScale, CpuScale.machineShare.rawValue)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: CompanionJSON.encode(snapshot)) as? [String: Any])
        for key in ["bandwidth", "cpuHistory", "settings"] { object.removeValue(forKey: key) }
        var pulseObject = try XCTUnwrap(object["pulse"] as? [String: Any])
        pulseObject.removeValue(forKey: "coreCount")
        object["pulse"] = pulseObject
        let legacy = try CompanionJSON.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.bandwidth)
        XCTAssertNil(legacy.cpuHistory)
        XCTAssertNil(legacy.settings)
        XCTAssertNil(legacy.pulse.coreCount)
    }

    func testThePhonesNamesForTheCpuScaleAreUnderstood() {
        XCTAssertEqual(CpuScale.fromPhone("Per Core"), .perCore)
        XCTAssertEqual(CpuScale.fromPhone("Share of Machine"), .machineShare)
        XCTAssertEqual(CpuScale.fromPhone("per machine"), .machineShare)
        XCTAssertNil(CpuScale.fromPhone("Sideways"))
        for scale in CpuScale.allCases {
            XCTAssertEqual(CpuScale.fromPhone(scale.rawValue), scale, "the raw value the phone echoes back must map to itself")
        }
        let request = CompanionHTTP.viewRequest(token: "t", cpuScale: "Share of Machine")
        let text = String(data: request, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("cpuScale=Share%20of%20Machine"), text)
    }
}

// MARK: - Sample for 3 Seconds

final class CompanionSampleRouteTests: XCTestCase {
    private let code = "ABCD2345"
    private var deviceToken = ""
    private let lan = CompanionPeer(key: "192.168.1.20", isTrusted: true)
    private let wan = CompanionPeer(key: "203.0.113.9", isTrusted: false)
    private let key = ProcessKey(pid: 100, startTime: 11)

    private func server(quit: Bool) -> CompanionServer {
        let server = CompanionServer()
        server.updateToken(code)
        deviceToken = server.devices.issue(name: "Test iPhone").token
        server.allowRemoteQuit = quit
        let row = HogRow(id: "p-100-11", keys: [key], name: "tool", detail: "", cpuPercent: 0, memoryBytes: 0, peakMemoryBytes: nil, presence: nil, icon: nil, path: nil, isApp: false, isGroup: false, canQuit: true, quitBlockReason: nil)
        server.update(snapshot: CompanionServerRoutingTests.minimalSnapshot(), targets: CompanionTargets.index([row]))
        server.syncOnQueue {}
        return server
    }

    private func disposition(_ server: CompanionServer, _ request: Data, from peer: CompanionPeer? = nil) -> CompanionServer.Disposition {
        server.syncOnQueue { server.disposition(for: request, peer: peer ?? lan) }
    }

    private func status(of disposition: CompanionServer.Disposition) -> Int? {
        guard case .reply(let data) = disposition else { return nil }
        return CompanionHTTP.parseResponse(data)?.status
    }

    func testASampleIsStartedOffTheRouterNotRunOnTheServerQueue() {
        let server = server(quit: true)
        var handlerCalls = 0
        server.onRemoteSample = { _, _ in handlerCalls += 1 }
        let result = disposition(server, CompanionHTTP.sampleRequest(token: deviceToken, rowId: "p-100-11"))
        XCTAssertEqual(result, .startSample(CompanionTarget(rowId: "p-100-11", name: "tool", members: [key])))
        XCTAssertEqual(handlerCalls, 0, "routing must not run the sample on the server queue")
    }

    func testASnapshotPollIsStillAnsweredWhileASampleIsHeld() {
        let server = server(quit: true)
        server.onRemoteSample = { _, _ in }
        _ = disposition(server, CompanionHTTP.sampleRequest(token: deviceToken, rowId: "p-100-11"))
        XCTAssertEqual(status(of: disposition(server, CompanionHTTP.request(token: code))), 200)
    }

    func testASampleIsRefusedUntilTheOwnerAllowsProcessControl() throws {
        let server = server(quit: false)
        server.onRemoteSample = { _, _ in XCTFail("must not start") }
        let result = disposition(server, CompanionHTTP.sampleRequest(token: deviceToken, rowId: "p-100-11"))
        guard case .reply(let data) = result else { return XCTFail("expected an inline refusal") }
        let parsed = try XCTUnwrap(CompanionHTTP.parseResponse(data))
        XCTAssertEqual(parsed.status, 403)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: parsed.body) as? [String: String])
        XCTAssertTrue(json["error"]?.contains("Allow iPhone to Quit or Tame Apps & Processes") ?? false)
        XCTAssertTrue(json["error"]?.contains("\u{00A0}") ?? false)
    }

    func testASampleIsRefusedFromAnUntrustedAddressAndWithTheSharedCode() {
        let server = server(quit: true)
        server.onRemoteSample = { _, _ in XCTFail("must not start") }
        XCTAssertEqual(status(of: disposition(server, CompanionHTTP.sampleRequest(token: deviceToken, rowId: "p-100-11"), from: wan)), 403)
        XCTAssertEqual(status(of: disposition(server, CompanionHTTP.sampleRequest(token: code, rowId: "p-100-11"))), 403)
    }

    func testARowTheMacNoLongerShowsIsRefusedAndAPidAloneIsNotAnAddress() {
        let server = server(quit: true)
        server.onRemoteSample = { _, _ in XCTFail("must not start") }
        XCTAssertEqual(status(of: disposition(server, CompanionHTTP.sampleRequest(token: deviceToken, rowId: "p-999-1"))), 400)
        let pidOnly = Data("POST /v1/sample?pid=100 HTTP/1.1\r\nAuthorization: Bearer \(deviceToken)\r\n\r\n".utf8)
        XCTAssertEqual(status(of: disposition(server, pidOnly)), 400)
    }

    func testAHistoryRowCannotBeSampled() throws {
        let server = server(quit: true)
        server.onRemoteSample = { _, _ in XCTFail("must not start") }
        let result = disposition(server, CompanionHTTP.sampleRequest(token: deviceToken, rowId: "h-abc"))
        guard case .reply(let data) = result else { return XCTFail("expected an inline refusal") }
        let parsed = try XCTUnwrap(CompanionHTTP.parseResponse(data))
        XCTAssertEqual(parsed.status, 400)
        let response = try JSONDecoder().decode(CompanionSampleResponse.self, from: parsed.body)
        XCTAssertTrue(response.error?.contains("only in history") ?? false)
    }
}

final class SampleReportTests: XCTestCase {
    private let report = """
    Analysis of sampling tool (pid 100) every 1 millisecond
    Process:         tool [100]
    Call graph:
        2713 Thread_1234   DispatchQueue_1: com.apple.main-thread  (serial)
          2713 start  (in dyld) + 1  [0x1]

    Total number in stack (recursive counted multiple, when >=5):
            5       foo  (in tool) + 1  [0x2]

    Sort by top of stack, same collapsed (when >= 5):
            __psynch_cvwait  (in libsystem_kernel.dylib)        2400
            mach_msg2_trap  (in libsystem_kernel.dylib)        200
            -[NSApplication run]  (in AppKit)        96

    Binary Images:
           0x1000 -        0x2000  tool
    """

    func testTheSummaryIsTheTopOfStackSectionHeaviestFirst() {
        let lines = SampleReport.summary(of: report)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.first, "__psynch_cvwait  (in libsystem_kernel.dylib)        2400")
        XCTAssertEqual(lines.last, "-[NSApplication run]  (in AppKit)        96")
    }

    func testTheSummaryIsCappedAndEachLineIsCut() {
        let many = (0..<40).map { "        symbol\($0)  (in lib)  \(1000 - $0)" }.joined(separator: "\n")
        let lines = SampleReport.summary(of: "Sort by top of stack, same collapsed (when >= 5):\n\(many)\n\nBinary Images:\n")
        XCTAssertEqual(lines.count, 12)
        let long = "Sort by top of stack, same collapsed (when >= 5):\n" + String(repeating: "x", count: 400) + "\n"
        XCTAssertLessThanOrEqual(SampleReport.summary(of: long).first?.count ?? 0, 110)
    }

    func testAReportWithoutTheSectionYieldsNothingRatherThanGuessing() {
        XCTAssertEqual(SampleReport.summary(of: "Call graph:\n    1 foo\n"), [])
        XCTAssertEqual(SampleReport.summary(of: ""), [])
    }

    func testOnlyTheTailOfAHugeReportIsRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hoghunter-sample-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let filler = String(repeating: "filler line that is not wanted\n", count: 20_000)
        try (filler + report).write(to: url, atomically: true, encoding: .utf8)
        let tail = SampleReport.tailText(of: url, bytes: 4_096)
        XCTAssertLessThanOrEqual(tail.utf8.count, 4_096)
        XCTAssertEqual(SampleReport.summary(of: tail).count, 3)
        XCTAssertGreaterThan(SampleReport.byteCount(of: url) ?? 0, 600_000)
    }
}

final class SampleChoiceTests: XCTestCase {
    private var children: [Process] = []

    override func tearDown() {
        for child in children where child.isRunning { child.terminate() }
        children.removeAll()
        super.tearDown()
    }

    private func spawnSleeper() throws -> ProcessKey {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["120"]
        try process.run()
        children.append(process)
        var start: UInt64?
        for _ in 0..<50 {
            start = ProcessControl.startTime(process.processIdentifier)
            if start != nil { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return ProcessKey(pid: process.processIdentifier, startTime: try XCTUnwrap(start))
    }

    func testALiveProcessWhoseStartTimeMatchesMayBeSampled() throws {
        let key = try spawnSleeper()
        guard case .ready(let chosen, _) = ProcessControl.sampleChoice(members: [key], fallbackName: "sleep") else {
            return XCTFail("a live process of this user must be sampleable")
        }
        XCTAssertEqual(chosen, key)
    }

    func testARecycledPidIsNeverSampled() throws {
        let real = try spawnSleeper()
        let stale = ProcessKey(pid: real.pid, startTime: real.startTime &+ 1)
        XCTAssertEqual(ProcessControl.sampleChoice(members: [stale], fallbackName: "sleep"), .changed(name: "sleep"))
        XCTAssertEqual(ProcessControl.sampleChoice(members: [ProcessKey(pid: real.pid, startTime: 0)], fallbackName: "sleep"), .changed(name: "sleep"))
        XCTAssertEqual(ProcessControl.sampleChoice(members: [], fallbackName: "gone"), .changed(name: "gone"))
    }

    func testTheFirstGoodMemberOfAGroupIsChosen() throws {
        let stale = ProcessKey(pid: 999_999, startTime: 5)
        let good = try spawnSleeper()
        guard case .ready(let chosen, _) = ProcessControl.sampleChoice(members: [stale, good], fallbackName: "group") else {
            return XCTFail("expected the live member")
        }
        XCTAssertEqual(chosen, good)
    }

    func testHogHunterItselfIsNeverSampled() throws {
        let me = ProcessKey(pid: getpid(), startTime: try XCTUnwrap(ProcessControl.startTime(getpid())))
        guard case .blocked(_, let reason) = ProcessControl.sampleChoice(members: [me], fallbackName: "me") else {
            return XCTFail("this app must not sample itself")
        }
        XCTAssertEqual(reason, ProcessControl.thisAppReason)
    }

    func testAnotherUsersProcessAndPidOneAreBlocked() {
        XCTAssertEqual(ProcessControl.sampleBlockReason(pid: 4242, uid: getuid() &+ 1), ProcessControl.otherUserReason)
        XCTAssertEqual(ProcessControl.sampleBlockReason(pid: 1, uid: 0), ProcessControl.systemProcessReason)
        XCTAssertNil(ProcessControl.sampleBlockReason(pid: 4242, uid: getuid()))
    }
}


final class CompanionIncompleteRequestTests: XCTestCase {
    /// A client that closes its side before the body arrived has not sent a
    /// request.  The handler must not run.
    func testAConnectionThatClosesMidBodyNeverReachesTheHandler() throws {
        let code = "ABCD2345"
        let server = CompanionServer()
        server.updateToken(code)
        let token = server.devices.issue(name: "Test iPhone").token
        server.allowRemoteEdit = true
        let called = CompanionLocked(false)
        server.onRemoteSettings = { _ in called.value = true; return (200, Data("{}".utf8)) }
        let listening = expectation(description: "listening")
        let port = CompanionLocked<UInt16>(0)
        server.start(name: "test", peerID: "test", token: code, advertise: false, preferredPort: nil, loopbackOnly: true) { status in
            if status.hasPrefix("Sharing on port "), let value = UInt16(status.dropFirst("Sharing on port ".count)) {
                port.value = value
                listening.fulfill()
            }
        }
        wait(for: [listening], timeout: 5)
        defer { server.stop() }

        let whole = CompanionHTTP.settingsRequest(token: token, update: CompanionSettingsUpdateRequest(alertsEnabled: true))
        let cutShort = whole.prefix(whole.count - 4)
        let queue = DispatchQueue(label: "hoghunter.tests.cutshort")
        let client = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(NWEndpoint.Port(rawValue: port.value)), using: .tcp)
        let sent = expectation(description: "sent")
        client.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            client.send(content: Data(cutShort), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in sent.fulfill() })
        }
        client.start(queue: queue)
        wait(for: [sent], timeout: 5)
        Thread.sleep(forTimeInterval: 0.7)
        client.cancel()
        XCTAssertFalse(called.value, "a request whose body never finished arriving must not be acted on")
    }
}

final class CompanionTrustedEndpointTests: XCTestCase {
    private func host(_ text: String, port: UInt16 = 24240) -> NWEndpoint {
        .hostPort(host: NWEndpoint.Host(text), port: NWEndpoint.Port(rawValue: port)!)
    }

    func testAddressesOnTheLocalNetworkAndTailscaleAreTrusted() {
        for address in ["192.168.1.20", "10.0.0.5", "172.20.3.4", "169.254.9.9", "127.0.0.1", "100.101.7.8", "fd7a:115c:a1e0::1", "fe80::1", "::1"] {
            XCTAssertTrue(CompanionPeer.isTrustedEndpoint(host(address)), address)
        }
    }

    func testPublicAddressesAreNot() {
        for address in ["8.8.8.8", "203.0.113.9", "100.63.0.1", "100.128.0.1", "2001:db8::1"] {
            XCTAssertFalse(CompanionPeer.isTrustedEndpoint(host(address)), address)
        }
    }

    func testOnlyMagicDnsAndLocalNamesAreTrusted() {
        for name in ["my-mac.tailnet.ts.net", "MY-MAC.TAILNET.TS.NET.", "studio.local", "studio.local.", "localhost", "localhost."] {
            XCTAssertTrue(CompanionPeer.isTrustedEndpoint(host(name)), name)
        }
        for name in ["example.com", "ts.net.evil.com", "mac.jays.services", "notts.net", "local"] {
            XCTAssertFalse(CompanionPeer.isTrustedEndpoint(host(name)), name)
        }
    }

    func testABonjourServiceWasFoundOnTheLocalLink() {
        XCTAssertTrue(CompanionPeer.isTrustedEndpoint(.service(name: "Studio", type: "_hoghunter._tcp", domain: "local.", interface: nil)))
    }
}

@MainActor
final class CompanionSampleGuardTests: XCTestCase {
    func testOnlyOneSampleRunsAtATimeAndTheGuardIsReleased() throws {
        let suite = "hoghunter.tests.sampleguard.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HogStore(defaults: defaults, infisical: IsolatedInfisical.make(), startImmediately: false)
        // A target whose pid and start time match nothing alive: it ends at the
        // identity check without running `sample` or writing a report.
        let stale = CompanionTarget(rowId: "p-999999-1", name: "gone", members: [ProcessKey(pid: 999_999, startTime: 1)])

        store.setSampleInFlightForTest(true)
        let busy = XCTestExpectation(description: "busy")
        store.performRemoteSample(target: stale) { reply in
            XCTAssertEqual(reply.status, 409)
            busy.fulfill()
        }
        wait(for: [busy], timeout: 2)

        store.setSampleInFlightForTest(false)
        for _ in 0..<2 {
            let done = XCTestExpectation(description: "refused at the identity check")
            store.performRemoteSample(target: stale) { reply in
                XCTAssertEqual(reply.status, 400, "the guard must be released after a refusal, or the second call would read 409")
                done.fulfill()
            }
            wait(for: [done], timeout: 2)
        }
    }
}

/// A request line ending in a bare `?` must never trap.  The parsers indexed the
/// second piece of a split on `?`, which does not exist then, so one such line
/// from a paired phone would have ended the Mac app.
final class CompanionQueryParsingTests: XCTestCase {
    func testQueryStringOfAPath() {
        XCTAssertEqual(CompanionHTTP.queryString(of: "/v1/view"), "")
        XCTAssertEqual(CompanionHTTP.queryString(of: "/v1/view?"), "")
        XCTAssertEqual(CompanionHTTP.queryString(of: "/v1/view?a=1&b=2"), "a=1&b=2")
        XCTAssertEqual(CompanionHTTP.queryString(of: "/v1/view?a=1?b=2"), "a=1?b=2")
        XCTAssertEqual(CompanionHTTP.queryString(of: "?"), "")
    }

    func testEveryRouteSurvivesABareQuestionMark() {
        let server = CompanionServer()
        server.updateToken("ABCD2345")
        let token = server.devices.issue(name: "Test iPhone").token
        server.allowRemoteQuit = true
        server.allowRemoteEdit = true
        server.allowRemoteClean = true
        server.onRemoteExclusionsUpdate = { _ in (200, Data("{}".utf8)) }
        server.onRemoteViewUpdate = { _ in (200, Data("{}".utf8)) }
        server.onRemoteQuit = { _, _ in (200, Data("{}".utf8)) }
        server.onRemoteTame = { _, _ in (200, Data("{}".utf8)) }
        server.syncOnQueue {}
        let lan = CompanionPeer(key: "192.168.1.20", isTrusted: true)
        let header = "Authorization: " + "Bearer " + token
        for path in ["/v1/view", "/v1/exclusions", "/v1/quit", "/v1/tame", "/v1/sample", "/v1/settings", "/v1/clean", "/v1/snapshot"] {
            for suffix in ["?", "?&", "?=", "??"] {
                let method = path == "/v1/snapshot" ? "GET" : "POST"
                let request = Data("\(method) \(path)\(suffix) HTTP/1.1\r\n\(header)\r\n\r\n".utf8)
                // Reaching the end of this loop is the assertion: a trap kills the run.
                _ = server.syncOnQueue { server.disposition(for: request, peer: lan) }
            }
        }
    }
}
