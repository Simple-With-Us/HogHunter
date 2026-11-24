import XCTest
@testable import HogHunter

final class CompanionWidgetCopyTests: XCTestCase {
    private func server() -> CompanionServerStatus {
        CompanionServerStatus(
            state: "ok",
            host: "server-one.example",
            generatedAt: Date(),
            fetchedAt: Date(),
            errorText: "connection refused by server-one.example",
            headline: CompanionServerHeadline(host: "server-one.example", cpuText: "41%", memoryText: "63%"),
            cpu: CompanionServerCPU(percent: 41, percentText: "41%", severity: "calm", cores: 8, loadText: "1.2", history: [10, 20, 41]),
            memory: CompanionServerMeter(percent: 63, percentText: "63%", detail: "10 of 16 GB", severity: "elevated"),
            processes: [CompanionServerProcess(id: "p1", name: "workload-private-name", cpuText: "9%", memoryText: "1 GB")]
        )
    }

    func testTheWidgetCopyHoldsOnlyTheServerNumbersItDraws() throws {
        var full = CompanionTestSnapshots.plain()
        full.remoteServerStatusAllowed = true
        full.server = server()
        let copy = full.widgetCopy()
        let kept = try XCTUnwrap(copy.server, "the widget needs the server's numbers")
        XCTAssertEqual(kept.cpu?.percentText, "41%")
        XCTAssertEqual(kept.memory?.percentText, "63%")
        XCTAssertEqual(kept.resolvedState(), .ok)
        XCTAssertNil(kept.host)
        XCTAssertNil(kept.errorText)
        XCTAssertNil(kept.headline)
        XCTAssertNil(kept.processes)
        XCTAssertNil(kept.cpu?.history)
        XCTAssertNil(kept.memory?.detail)
        let text = String(data: try CompanionJSON.encode(copy), encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("server-one.example"))
        XCTAssertFalse(text.contains("workload-private-name"))
    }

    func testTheWidgetCopyHasNoServerWhenThePhoneMayNotSeeIt() {
        var off = CompanionTestSnapshots.plain()
        off.remoteServerStatusAllowed = false
        off.server = nil
        XCTAssertNil(off.widgetCopy().server)
    }

    func testAnOldReadingStaysStaleInTheWidgetCopy() throws {
        var full = CompanionTestSnapshots.plain()
        full.remoteServerStatusAllowed = true
        var old = server()
        old.generatedAt = Date().addingTimeInterval(-3_600)
        full.server = old
        XCTAssertEqual(try XCTUnwrap(full.widgetCopy().server).resolvedState(), .stale)
    }
}
