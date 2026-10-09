import XCTest

@testable import HogHunter

/// Exclusion and view edits from the phone sit behind their own opt-in,
/// consistent with Quit and Clean.
final class CompanionEditOptInTests: XCTestCase {
    private let code = "ABCD2345"

    private func server(edit: Bool) -> CompanionServer {
        let server = CompanionServer()
        server.updateToken(code)
        server.allowRemoteEdit = edit
        server.syncOnQueue {}
        return server
    }

    private func status(_ server: CompanionServer, _ request: Data) -> Int? {
        guard case .reply(let data) = server.syncOnQueue({ server.disposition(for: request) }) else { return nil }
        return CompanionHTTP.parseResponse(data)?.status
    }

    func testExclusionsAreRefusedUntilTheOwnerAllowsEdits() {
        let server = server(edit: false)
        server.onRemoteExclusionsUpdate = { _ in XCTFail("must not reach the handler"); return (200, Data()) }
        XCTAssertEqual(status(server, CompanionHTTP.exclusionsRequest(token: code, toggleCategory: "trash")), 403)
    }

    func testViewChangesAreRefusedUntilTheOwnerAllowsEdits() {
        let server = server(edit: false)
        server.onRemoteViewUpdate = { _ in XCTFail("must not reach the handler"); return (200, Data()) }
        XCTAssertEqual(status(server, CompanionHTTP.viewRequest(token: code, window: "Past Hour")), 403)
    }

    func testTheRefusalNamesTheSettingToTurnOn() throws {
        let server = server(edit: false)
        guard case .reply(let data) = server.syncOnQueue({ server.disposition(for: CompanionHTTP.viewRequest(token: code, grouping: "Processes")) }) else {
            return XCTFail("expected an inline refusal")
        }
        let body = try XCTUnwrap(CompanionHTTP.parseResponse(data)?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertTrue(json["error"]?.contains("Allow iPhone to Change Exclusions & View") ?? false)
    }

    func testEditsReachTheHandlersOnceAllowed() {
        let server = server(edit: true)
        var exclusions: CompanionExclusionsUpdateRequest?
        var view: CompanionViewUpdateRequest?
        server.onRemoteExclusionsUpdate = { exclusions = $0; return (200, Data("{}".utf8)) }
        server.onRemoteViewUpdate = { view = $0; return (200, Data("{}".utf8)) }

        XCTAssertEqual(status(server, CompanionHTTP.exclusionsRequest(token: code, addPath: "/Users/jay/Keep")), 200)
        XCTAssertEqual(status(server, CompanionHTTP.viewRequest(token: code, window: "Now")), 200)
        XCTAssertEqual(exclusions?.addPath, "/Users/jay/Keep")
        XCTAssertEqual(view?.window, "Now")
    }

    func testTheOptInIsIndependentOfQuitAndClean() {
        let server = server(edit: false)
        server.allowRemoteQuit = true
        server.allowRemoteClean = true
        server.onRemoteExclusionsUpdate = { _ in XCTFail("must not reach the handler"); return (200, Data()) }
        XCTAssertEqual(status(server, CompanionHTTP.exclusionsRequest(token: code, toggleCategory: "trash")), 403)
    }

    func testTheSnapshotCarriesTheOptIn() throws {
        let snapshot = CompanionSnapshotBuilder.make(
            hostName: "test", sampledAt: Date(), hasBaseline: true,
            window: .now, grouping: .apps, scale: .perCore, pulse: MachinePulse.empty, rows: [],
            remoteQuitAllowed: false, remoteCleanAllowed: false, remoteEditAllowed: true
        )
        let decoded = try CompanionJSON.decode(CompanionJSON.encode(snapshot))
        XCTAssertEqual(decoded.remoteEditAllowed, true)

        // An older Mac omits the field.  That must decode as unknown, not fail.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: CompanionJSON.encode(snapshot)) as? [String: Any])
        object.removeValue(forKey: "remoteEditAllowed")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(try CompanionJSON.decode(legacy).remoteEditAllowed)
    }

    @MainActor
    func testTheOptInSurvivesARestartAndDefaultsOff() {
        let suite = "hoghunter.tests.remoteedit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = HogStore(defaults: defaults)
        XCTAssertFalse(first.allowRemoteEdit, "off until the owner turns it on")
        first.allowRemoteEdit = true
        XCTAssertEqual(defaults.bool(forKey: "allowRemoteEdit"), true)

        let second = HogStore(defaults: defaults)
        XCTAssertTrue(second.allowRemoteEdit)
    }
}
