import XCTest

@testable import HogHunter

// Phone parity, batch 2, PR B: the disk cleaner on the phone.  Nothing here
// walks a real folder or deletes a real file: scans are stubbed and cleans use
// a file manager that only records what it was asked to remove.

/// Records what a clean asks the file system to do, and does none of it.
final class RecordingFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var trashedPaths: [String] = []
    private var removedPaths: [String] = []

    var trashed: [String] { lock.lock(); defer { lock.unlock() }; return trashedPaths }
    var removed: [String] { lock.lock(); defer { lock.unlock() }; return removedPaths }

    override func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        lock.lock(); trashedPaths.append(url.path); lock.unlock()
    }

    override func removeItem(at url: URL) throws {
        lock.lock(); removedPaths.append(url.path); lock.unlock()
    }
}

enum CleanerFixtures {
    static let home = NSHomeDirectory()

    static func item(_ category: CleanCategory, _ name: String, bytes: UInt64, selected: Bool = true) -> CleanItem {
        let folder: String
        switch category {
        case .userCaches: folder = "/Library/Caches/"
        case .trash: folder = "/.Trash/"
        default: folder = "/Library/Caches/"
        }
        return CleanItem(
            category: category,
            title: name,
            subtitle: "~\(folder)\(name)",
            url: URL(fileURLWithPath: home + folder + name),
            bytes: bytes,
            fileCount: 3,
            lastModified: nil,
            isSelected: selected,
            detail: nil
        )
    }

    static func report(tier: CleanTier = .standard, _ categories: [(CleanCategory, [CleanItem])]) -> CleanScanReport {
        let reports = categories.map { category, items in
            CleanCategoryReport(
                category: category,
                items: items,
                totalBytes: items.reduce(0) { $0 + $1.bytes },
                selectedBytes: items.filter(\.isSelected).reduce(0) { $0 + $1.bytes },
                itemCount: items.count
            )
        }
        return CleanScanReport(
            categories: reports,
            totalBytes: reports.reduce(0) { $0 + $1.totalBytes },
            totalSelectedBytes: reports.reduce(0) { $0 + $1.selectedBytes },
            scannedAt: Date(),
            tier: tier
        )
    }

    /// Two categories: caches (default selected) and AI artifacts (not).
    static func sampleReport(tier: CleanTier = .standard) -> CleanScanReport {
        report(tier: tier, [
            (.userCaches, [
                item(.userCaches, "TestCacheSmall", bytes: 10),
                item(.userCaches, "TestCacheBig", bytes: 5_000),
                item(.userCaches, "TestCacheUnticked", bytes: 700, selected: false),
            ]),
            (.aiArtifacts, [
                item(.aiArtifacts, "TestAgentRun", bytes: 9_000, selected: true),
            ]),
        ])
    }
}

// MARK: - The report and the plan

final class CompanionCleanerReportTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func scan(tier: CleanTier = .standard, id: String = "scan-1") -> RemoteCleanScan {
        var built = CompanionCleanerReport.build(from: CleanerFixtures.sampleReport(tier: tier), id: id)
        built.scannedAt = t0
        return built
    }

    func testItemsAreLargestFirstAndReferencedByPosition() {
        let built = scan()
        let caches = built.categories[0]
        XCTAssertEqual(caches.items.map(\.title), ["TestCacheBig", "TestCacheUnticked", "TestCacheSmall"])
        XCTAssertEqual(caches.items.map(\.id), ["0.0", "0.1", "0.2"])
        XCTAssertEqual(built.refs["0.0"]?.title, "TestCacheBig")
        XCTAssertEqual(built.refs.count, 4)
        XCTAssertEqual(built.totalItems, 4)
    }

    func testAnItemStartsTickedOnlyWhenTheMacsCleanerWouldTickIt() {
        let built = scan()
        XCTAssertEqual(built.categories[0].items.first { $0.title == "TestCacheBig" }?.isSelected, true)
        XCTAssertEqual(built.categories[0].items.first { $0.title == "TestCacheUnticked" }?.isSelected, false, "an item the scan left unticked stays unticked")
        // AI artifacts are not selected by default, whatever the item says.
        XCTAssertEqual(built.categories[1].items.first?.isSelected, false)
        XCTAssertEqual(built.defaultRefs, ["0.0", "0.2"])
    }

    func testDefaultSelectionMatchesWhatTheMacWouldTick() {
        let titles = CompanionCleanerReport.defaultSelection(of: CleanerFixtures.sampleReport()).map(\.title).sorted()
        XCTAssertEqual(titles, ["TestCacheBig", "TestCacheSmall"])
    }

    func testACategoryListsAtMostTheLargestHundredAndCountsTheRest() {
        let items = (0..<250).map { CleanerFixtures.item(.userCaches, "TestCache\($0)", bytes: UInt64($0 + 1)) }
        let built = CompanionCleanerReport.build(from: CleanerFixtures.report([(.userCaches, items)]), id: "big")
        XCTAssertEqual(built.categories[0].items.count, CompanionCleanerReport.itemsPerCategory)
        XCTAssertEqual(built.categories[0].itemCount, 250)
        XCTAssertEqual(built.categories[0].items.first?.bytes, 250)
        XCTAssertEqual(built.refs.count, CompanionCleanerReport.itemsPerCategory)
    }

    func testNoFilesystemPathReachesThePhone() throws {
        let home = CleanerFixtures.home
        var report = CompanionCleanReport(state: "ready")
        let built = scan()
        report.categories = built.categories
        report.scanId = built.id
        // JSON escapes a slash as "\/", which would hide a leaked path from a plain search.
        let json = try XCTUnwrap(String(data: CompanionJSON.encoder().encode(report), encoding: .utf8)).replacingOccurrences(of: "\\/", with: "/")
        XCTAssertFalse(json.contains(home), "the report must not carry an absolute path: \(json)")
        XCTAssertTrue(json.contains("~/Library/Caches/TestCacheBig"), "the home-relative subtitle is what the phone shows")
    }

    func testAPlanResolvesReferencesAgainstTheMacsOwnScan() throws {
        let built = scan()
        let request = CompanionCleanRequest(scanId: "scan-1", tier: "standard", items: ["0.2", "0.0"], acknowledgedExtreme: nil)
        let plan = try CompanionCleanerReport.plan(for: request, scan: built, now: t0.addingTimeInterval(60)).get()
        XCTAssertEqual(plan.tier, .standard)
        XCTAssertEqual(plan.items.map(\.title), ["TestCacheBig", "TestCacheSmall"], "the Mac's own order, not the phone's")
        XCTAssertEqual(plan.items.first?.url.path, CleanerFixtures.home + "/Library/Caches/TestCacheBig")
    }

    func testDuplicateReferencesCleanAnItemOnce() throws {
        let request = CompanionCleanRequest(scanId: "scan-1", tier: "standard", items: ["0.0", "0.0", "0.0"], acknowledgedExtreme: nil)
        XCTAssertEqual(try CompanionCleanerReport.plan(for: request, scan: scan(), now: t0).get().items.count, 1)
    }

    func testThereIsNothingToCleanWithoutAScan() {
        let request = CompanionCleanRequest(scanId: "scan-1", tier: "standard", items: ["0.0"])
        guard case .failure(let refusal) = CompanionCleanerReport.plan(for: request, scan: nil, now: t0) else { return XCTFail("cleaned without a scan") }
        XCTAssertEqual(refusal.status, 409)
        XCTAssertTrue(refusal.message.contains("\u{00A0}"))
    }

    func testAStaleOrDifferentScanIsRefused() {
        let built = scan()
        for request in [
            CompanionCleanRequest(scanId: "scan-0", tier: "standard", items: ["0.0"]),
            CompanionCleanRequest(scanId: nil, tier: "standard", items: ["0.0"]),
        ] {
            guard case .failure(let refusal) = CompanionCleanerReport.plan(for: request, scan: built, now: t0) else { return XCTFail("cleaned from the wrong scan") }
            XCTAssertEqual(refusal.status, 409)
        }
        let aged = t0.addingTimeInterval(CompanionCleanerReport.scanLifetime + 1)
        guard case .failure(let refusal) = CompanionCleanerReport.plan(for: CompanionCleanRequest(scanId: "scan-1", tier: "standard", items: ["0.0"]), scan: built, now: aged) else {
            return XCTFail("cleaned from an expired scan")
        }
        XCTAssertEqual(refusal.status, 409)
    }

    func testAnUnknownReferenceRefusesTheWholeRequest() {
        for bad in ["9.9", "0.3", "/Users/jay/Documents", "../../etc", "", "0.0 "] {
            let request = CompanionCleanRequest(scanId: "scan-1", tier: "standard", items: ["0.0", bad])
            guard case .failure(let refusal) = CompanionCleanerReport.plan(for: request, scan: scan(), now: t0) else { return XCTFail("accepted \(bad)") }
            XCTAssertEqual(refusal.status, 400)
        }
    }

    func testNothingSelectedIsRefused() {
        for items in [nil, []] as [[String]?] {
            guard case .failure(let refusal) = CompanionCleanerReport.plan(for: CompanionCleanRequest(scanId: "scan-1", tier: "standard", items: items), scan: scan(), now: t0) else {
                return XCTFail("cleaned nothing successfully")
            }
            XCTAssertEqual(refusal.status, 400)
        }
    }

    func testTheTierMustMatchTheScan() {
        let extremeScan = scan(tier: .extreme)
        let mismatched = CompanionCleanRequest(scanId: "scan-1", tier: "standard", items: ["0.0"], acknowledgedExtreme: true)
        guard case .failure(let refusal) = CompanionCleanerReport.plan(for: mismatched, scan: extremeScan, now: t0) else { return XCTFail("tier mismatch accepted") }
        XCTAssertEqual(refusal.status, 409)
        guard case .failure(let unknown) = CompanionCleanerReport.plan(for: CompanionCleanRequest(scanId: "scan-1", tier: "reckless", items: ["0.0"]), scan: scan(), now: t0) else { return XCTFail("unknown tier accepted") }
        XCTAssertEqual(unknown.status, 400)
    }

    func testExtremeNeedsTheAcknowledgementToCleanAndToScan() throws {
        let extremeScan = scan(tier: .extreme)
        for ack in [nil, false] as [Bool?] {
            let request = CompanionCleanRequest(scanId: "scan-1", tier: "extreme", items: ["0.0"], acknowledgedExtreme: ack)
            guard case .failure(let refusal) = CompanionCleanerReport.plan(for: request, scan: extremeScan, now: t0) else { return XCTFail("Extreme cleaned unacknowledged") }
            XCTAssertEqual(refusal.status, 400)
            XCTAssertEqual(refusal.message, CompanionCleanerReport.extremeNeedsAcknowledgement)
        }
        let acknowledged = CompanionCleanRequest(scanId: "scan-1", tier: "extreme", items: ["0.0"], acknowledgedExtreme: true)
        XCTAssertEqual(try CompanionCleanerReport.plan(for: acknowledged, scan: extremeScan, now: t0).get().tier, .extreme)

        guard case .failure(let scanRefusal) = CompanionCleanerReport.validate(CompanionCleanScanRequest(tier: "extreme")) else { return XCTFail("Extreme scanned unacknowledged") }
        XCTAssertEqual(scanRefusal.status, 400)
        XCTAssertEqual(try CompanionCleanerReport.validate(CompanionCleanScanRequest(tier: "extreme", acknowledgedExtreme: true)).get(), .extreme)
        XCTAssertEqual(try CompanionCleanerReport.validate(CompanionCleanScanRequest(tier: "standard")).get(), .standard)
        guard case .failure = CompanionCleanerReport.validate(CompanionCleanScanRequest(tier: "bogus")) else { return XCTFail("unknown tier scanned") }
    }

    func testTheRefusalsKeepTheirGapAndReadAsJSON() throws {
        let refusal = CompanionCleanerReport.Refusal(status: 409, message: "That scan is out of date.\u{00A0} Scan again.")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: refusal.reply.body) as? [String: String])
        XCTAssertEqual(json["status"], "rejected")
        XCTAssertTrue(json["error"]?.contains("\u{00A0}") ?? false)
        XCTAssertFalse(CompanionCleanerReport.extremeNeedsAcknowledgement.contains(".  "))
    }

    func testSharedCopyKeepsItsGapAndItsMeaning() {
        let confirmation = CleanerCopy.confirmationMessage(sizeText: "1.2 GB", itemCount: 14)
        XCTAssertTrue(confirmation.hasPrefix("Are you sure you want to clean 1.2 GB across 14 items?"))
        XCTAssertTrue(confirmation.contains("If that snapshot fails, nothing is deleted."))
        XCTAssertTrue(confirmation.contains("Items already in the Trash are removed permanently."))
        XCTAssertTrue(confirmation.contains("\u{00A0}"))
        XCTAssertFalse(confirmation.contains(".  "), "two ASCII spaces collapse on the phone")
        XCTAssertTrue(CleanerCopy.extremeBody.contains("older AI agent transcripts (>7 days)"))
        XCTAssertTrue(CleanerCopy.extremeBody.contains("git repositories and critical directories are strictly protected"))
    }

    func testTheHistoryRowTheMacWritesAndThePhoneReads() throws {
        let cleaned = CleanResult(
            bytesReclaimed: 5_010, itemsRemoved: 2, errors: [], cleanedAt: t0, snapshotName: "snap", tier: .standard,
            removedItemTitles: ["a", "b", "c", "d", "e", "f", "g"], removedCategoryIds: ["userCaches", "nonsense"]
        )
        let record = try XCTUnwrap(CleanupHistoryRecord.record(from: cleaned, source: "iPhone"))
        XCTAssertEqual(record.source, "iPhone")
        XCTAssertEqual(record.snapshotName, "snap")
        let phone = CompanionCleanerReport.record(record)
        XCTAssertEqual(phone.itemTitles, ["a", "b", "c", "d", "e"], "the phone gets the first five titles")
        XCTAssertEqual(phone.categoryTitles, ["User Caches"], "an unknown category id is dropped, not shown raw")
        XCTAssertEqual(phone.tier, "standard")
        XCTAssertEqual(phone.source, "iPhone")

        let failed = CleanResult(bytesReclaimed: 0, itemsRemoved: 0, errors: ["no"], cleanedAt: t0)
        XCTAssertNil(CleanupHistoryRecord.record(from: failed), "a clean that removed nothing leaves no row")
    }
}

// MARK: - History on disk

final class CleanupHistoryParityTests: XCTestCase {
    private func record(_ n: Int, source: String? = nil) -> CleanupHistoryRecord {
        CleanupHistoryRecord(bytesReclaimed: UInt64(n), itemsRemoved: 1, tier: .standard, categoryIds: ["userCaches"], itemTitles: ["t\(n)"], snapshotName: nil, source: source, cleanedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(n)))
    }

    func testRecentRecordsAreNewestFirstAndBounded() {
        let store = CleanupHistoryStore(inMemory: true)
        defer { try? FileManager.default.removeItem(at: store.url) }
        for n in 1...30 { store.append(record(n)) }
        let recent = store.recentRecords(limit: 10)
        XCTAssertEqual(recent.count, 10)
        XCTAssertEqual(recent.first?.bytesReclaimed, 30)
        XCTAssertEqual(recent.last?.bytesReclaimed, 21)
        XCTAssertEqual(store.recentRecords(limit: 0).count, 0)
    }

    func testARowWithoutASourceStillReadsAndASourceSurvives() throws {
        let store = CleanupHistoryStore(inMemory: true)
        defer { try? FileManager.default.removeItem(at: store.url) }
        let legacy = #"{"cleanedAt":"2026-10-01T10:00:00Z","bytesReclaimed":7,"itemsRemoved":1,"tier":"standard","categoryIds":[],"itemTitles":[]}"#
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (legacy + "\n").write(to: store.url, atomically: true, encoding: .utf8)
        store.append(record(8, source: "iPhone"))
        let recent = store.recentRecords(limit: 5)
        XCTAssertEqual(recent.map(\.bytesReclaimed), [8, 7])
        XCTAssertEqual(recent.first?.source, "iPhone")
        XCTAssertNil(recent.last?.source)
    }

    func testACorruptLineIsSkippedNotFatal() throws {
        let store = CleanupHistoryStore(inMemory: true)
        defer { try? FileManager.default.removeItem(at: store.url) }
        store.append(record(1))
        let handle = try FileHandle(forWritingTo: store.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not json\n".utf8))
        try handle.close()
        store.append(record(2))
        XCTAssertEqual(store.recentRecords(limit: 5).map(\.bytesReclaimed), [2, 1])
    }

    func testTwoInstancesAppendingAtOnceLoseNoRow() {
        let first = CleanupHistoryStore(inMemory: true)
        let second = CleanupHistoryStore(url: first.url)
        defer { try? FileManager.default.removeItem(at: first.url) }
        let group = DispatchGroup()
        for (offset, store) in [first, second].enumerated() {
            group.enter()
            DispatchQueue.global().async {
                for n in 0..<60 { store.append(CleanupHistoryRecord(bytesReclaimed: UInt64(offset * 1_000 + n + 1), itemsRemoved: 1, tier: .standard, categoryIds: [], itemTitles: [], snapshotName: nil)) }
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(first.allRecords().count, 120, "the Mac's cleaner and the phone's each own an instance; their appends must not interleave")
    }
}

// MARK: - Routes

final class CompanionCleanerRouteTests: XCTestCase {
    private let code = "ABCD2345"
    private var deviceToken = ""
    private let lan = CompanionPeer(key: "192.168.1.20", isTrusted: true)
    private let wan = CompanionPeer(key: "203.0.113.9", isTrusted: false)

    private func server(clean: Bool) -> CompanionServer {
        let server = CompanionServer()
        server.updateToken(code)
        deviceToken = server.devices.issue(name: "Test iPhone").token
        server.allowRemoteClean = clean
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

    private func allRoutes() -> [(String, Data)] {
        [
            ("scan", CompanionHTTP.cleanScanRequest(token: deviceToken, tier: "standard", acknowledgedExtreme: false)),
            ("report", CompanionHTTP.cleanReportRequest(token: deviceToken)),
            ("clean", CompanionHTTP.cleanRequest(token: deviceToken, request: CompanionCleanRequest(scanId: "s", tier: "standard", items: ["0.0"]))),
        ]
    }

    private func unreachable(_ server: CompanionServer) {
        server.onRemoteCleanScan = { _, _ in XCTFail("scan must not start") }
        server.onRemoteCleanReport = { _ in XCTFail("report must not be built") }
        server.onRemoteClean = { _, _ in XCTFail("clean must not start") }
    }

    func testEveryCleanerRouteIsRefusedUntilTheOwnerAllowsTheCleaner() throws {
        let server = server(clean: false)
        unreachable(server)
        for (name, request) in allRoutes() {
            let result = disposition(server, request)
            guard case .reply(let data) = result else { return XCTFail("\(name) was not refused inline") }
            let parsed = try XCTUnwrap(CompanionHTTP.parseResponse(data))
            XCTAssertEqual(parsed.status, 403, name)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: parsed.body) as? [String: String])
            XCTAssertTrue(json["error"]?.contains("Allow iPhone to Run Disk Cleaner") ?? false, name)
            XCTAssertTrue(json["error"]?.contains("\u{00A0}") ?? false, name)
        }
    }

    func testEveryCleanerRouteIsRefusedFromAnUntrustedAddressAndWithTheSharedCode() {
        let server = server(clean: true)
        unreachable(server)
        for (name, request) in allRoutes() {
            XCTAssertEqual(status(of: disposition(server, request, from: wan)), 403, "\(name) from outside")
        }
        let shared: [(String, Data)] = [
            ("scan", CompanionHTTP.cleanScanRequest(token: code, tier: "standard", acknowledgedExtreme: false)),
            ("report", CompanionHTTP.cleanReportRequest(token: code)),
            ("clean", CompanionHTTP.cleanRequest(token: code, request: CompanionCleanRequest(scanId: "s", items: ["0.0"]))),
        ]
        for (name, request) in shared {
            XCTAssertEqual(status(of: disposition(server, request)), 403, "\(name) with the shared code")
        }
        XCTAssertEqual(status(of: disposition(server, CompanionHTTP.cleanReportRequest(token: "hh1_wrong"))), 401)
    }

    func testTheRoutesAreHeldOffTheRouterOnceAllowed() {
        let server = server(clean: true)
        let calls = CompanionLocked(0)
        server.onRemoteCleanScan = { _, _ in calls.value += 1 }
        server.onRemoteCleanReport = { _ in calls.value += 1 }
        server.onRemoteClean = { _, _ in calls.value += 1 }

        XCTAssertEqual(disposition(server, CompanionHTTP.cleanScanRequest(token: deviceToken, tier: "extreme", acknowledgedExtreme: true)),
                       .startCleanScan(CompanionCleanScanRequest(tier: "extreme", acknowledgedExtreme: true)))
        XCTAssertEqual(disposition(server, CompanionHTTP.cleanScanRequest(token: deviceToken, tier: "Standard", acknowledgedExtreme: false)),
                       .startCleanScan(CompanionCleanScanRequest(tier: "standard", acknowledgedExtreme: false)))
        XCTAssertEqual(disposition(server, CompanionHTTP.cleanReportRequest(token: deviceToken)), .startCleanReport)
        let request = CompanionCleanRequest(scanId: "scan-1", tier: "standard", items: ["0.1", "1.0"], acknowledgedExtreme: nil)
        XCTAssertEqual(disposition(server, CompanionHTTP.cleanRequest(token: deviceToken, request: request)), .startClean(request))
        XCTAssertEqual(calls.value, 0, "routing must not run any of them on the server queue")
    }

    func testABareCleanFromAnOlderPhoneIsTheStandardCleanRequestWithNoBody() {
        let server = server(clean: true)
        server.onRemoteClean = { _, _ in }
        XCTAssertEqual(disposition(server, CompanionHTTP.cleanRequest(token: deviceToken)), .startClean(nil))
    }

    func testAnUnreadableCleanBodyIsRefusedNotGuessedAt() {
        let server = server(clean: true)
        server.onRemoteClean = { _, _ in XCTFail("must not start") }
        var request = CompanionHTTP.cleanRequest(token: deviceToken, request: CompanionCleanRequest(scanId: "s", items: ["0.0"]))
        request.replaceSubrange(request.range(of: Data("{".utf8))!, with: Data("[".utf8))
        XCTAssertEqual(status(of: disposition(server, request)), 400)
    }

    func testTheMethodsAreChecked() {
        let server = server(clean: true)
        unreachable(server)
        let getScan = Data("GET /v1/clean/scan?tier=standard HTTP/1.1\r\nAuthorization: Bearer \(deviceToken)\r\n\r\n".utf8)
        let postReport = Data("POST /v1/clean/report HTTP/1.1\r\nAuthorization: Bearer \(deviceToken)\r\n\r\n".utf8)
        XCTAssertEqual(status(of: disposition(server, getScan)), 405)
        XCTAssertEqual(status(of: disposition(server, postReport)), 405)
    }

    func testTheReportAndScanTravelOnlyWhatTheyNeed() throws {
        let scanText = String(data: CompanionHTTP.cleanScanRequest(token: deviceToken, tier: "extreme", acknowledgedExtreme: true), encoding: .utf8) ?? ""
        XCTAssertTrue(scanText.hasPrefix("POST /v1/clean/scan?tier=extreme&ack=1 HTTP/1.1"))
        let cleanBody = CompanionHTTP.bodyData(of: CompanionHTTP.cleanRequest(token: deviceToken, request: CompanionCleanRequest(scanId: "s", tier: "standard", items: ["0.0"])))
        let decoded = try JSONDecoder().decode(CompanionCleanRequest.self, from: cleanBody)
        XCTAssertEqual(decoded.items, ["0.0"])
        XCTAssertFalse(String(data: cleanBody, encoding: .utf8)?.contains("/") ?? true, "the clean request names references, never paths")
    }

    func testTheLargestRealisticCleanRequestFitsTheBodyCap() {
        // Nine categories of a hundred items each, every one ticked.
        let items = (0..<9).flatMap { category in (0..<100).map { "\(category).\($0)" } }
        let request = CompanionHTTP.cleanRequest(token: deviceToken, request: CompanionCleanRequest(scanId: UUID().uuidString, tier: "extreme", items: items, acknowledgedExtreme: true))
        XCTAssertEqual(CompanionHTTP.completeness(of: request), .complete)
        XCTAssertLessThan(CompanionHTTP.bodyData(of: request).count, CompanionHTTP.maxBodyBytes)
    }
}

// MARK: - The store

@MainActor
final class CompanionCleanerStoreTests: XCTestCase {
    private var history: CleanupHistoryStore!
    private var store: HogStore!
    private var suite = ""

    override func setUp() async throws {
        suite = "hoghunter.tests.cleaner.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        history = CleanupHistoryStore(inMemory: true)
        store = HogStore(defaults: defaults, infisical: IsolatedInfisical.make(), cleanupHistory: history, startImmediately: false)
        store.remoteExclusions = { CleanerExclusions() }
    }

    override func tearDown() async throws {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: history.url)
    }

    private func report(of reply: CompanionServer.Reply) throws -> CompanionCleanReport {
        XCTAssertEqual(reply.status, 200)
        return try CompanionJSON.decoder().decode(CompanionCleanReport.self, from: reply.body)
    }

    private func waitForScan() async throws {
        for _ in 0..<150 {
            if case .ready = store.remoteScanState { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("the scan never finished")
    }

    private func scanReady(tier: String = "standard", acknowledged: Bool = false) async throws -> CompanionCleanReport {
        store.remoteScanner = { tier, progress in
            progress("User Caches")
            return CleanerFixtures.sampleReport(tier: tier)
        }
        let started = store.beginRemoteCleanScan(CompanionCleanScanRequest(tier: tier, acknowledgedExtreme: acknowledged))
        XCTAssertEqual(started.status, 202)
        try await waitForScan()
        return try report(of: store.remoteCleanReportReply())
    }

    func testAScanRunsOffTheMainActorAndTheReportFollowsIt() async throws {
        let before = try report(of: store.remoteCleanReportReply())
        XCTAssertEqual(before.state, "idle")

        let ready = try await scanReady()
        XCTAssertEqual(ready.state, "ready")
        XCTAssertEqual(ready.tier, "standard")
        XCTAssertEqual(ready.categories.count, 2)
        XCTAssertNotNil(ready.scanId)
    }

    func testASecondScanIsRefusedWhileOneRuns() async throws {
        store.remoteScanner = { tier, _ in
            try? await Task.sleep(nanoseconds: 400_000_000)
            return CleanerFixtures.sampleReport(tier: tier)
        }
        XCTAssertEqual(store.beginRemoteCleanScan(CompanionCleanScanRequest(tier: "standard")).status, 202)
        XCTAssertEqual(store.beginRemoteCleanScan(CompanionCleanScanRequest(tier: "standard")).status, 409)
        let during = try report(of: store.remoteCleanReportReply())
        XCTAssertEqual(during.state, "scanning")
        XCTAssertTrue(during.categories.isEmpty, "a scan in progress sends no items")
        try await waitForScan()
    }

    func testExtremeIsNotScannedWithoutTheAcknowledgement() throws {
        store.remoteScanner = { _, _ in XCTFail("must not scan"); return CleanerFixtures.sampleReport() }
        let refused = store.beginRemoteCleanScan(CompanionCleanScanRequest(tier: "extreme", acknowledgedExtreme: false))
        XCTAssertEqual(refused.status, 400)
        XCTAssertEqual(try report(of: store.remoteCleanReportReply()).state, "idle")
    }

    func testACleanFromAScanTrashesOnlyWhatWasChosenAndIsRecorded() async throws {
        let ready = try await scanReady()
        let big = try XCTUnwrap(ready.categories[0].items.first { $0.title == "TestCacheBig" })
        let files = RecordingFileManager()
        store.remoteCleanerFactory = { DiskCleaner(fileManager: files, makeSnapshot: { (true, "snap-test") }) }

        let request = CompanionCleanRequest(scanId: ready.scanId, tier: "standard", items: [big.id], acknowledgedExtreme: nil)
        let reply = await store.runRemoteClean(request: request)

        XCTAssertEqual(reply.status, 200)
        let response = try JSONDecoder().decode(CompanionCleanResponse.self, from: reply.body)
        XCTAssertEqual(response.itemsRemoved, 1)
        XCTAssertEqual(files.trashed, [CleanerFixtures.home + "/Library/Caches/TestCacheBig"], "only the chosen item, and nothing else, was touched")
        XCTAssertTrue(files.removed.isEmpty)

        let rows = history.allRecords()
        XCTAssertEqual(rows.count, 1, "a phone clean is recorded like a Mac clean")
        XCTAssertEqual(rows.first?.source, "iPhone")
        XCTAssertEqual(rows.first?.itemsRemoved, 1)
        XCTAssertEqual(rows.first?.snapshotName, "snap-test")

        // The scan is spent: the same request again has nothing to clean from.
        let again = await store.runRemoteClean(request: request)
        XCTAssertEqual(again.status, 409)
        XCTAssertEqual(files.trashed.count, 1)
        // And the report now carries the history.
        let after = try report(of: store.remoteCleanReportReply())
        XCTAssertEqual(after.state, "idle")
        XCTAssertEqual(after.history.count, 1)
        XCTAssertEqual(after.history.first?.source, "iPhone")
    }

    func testACleanWhoseSnapshotFailsDeletesNothingAndLeavesNoRow() async throws {
        let ready = try await scanReady()
        let files = RecordingFileManager()
        store.remoteCleanerFactory = { DiskCleaner(fileManager: files, makeSnapshot: { (false, nil) }) }
        let request = CompanionCleanRequest(scanId: ready.scanId, tier: "standard", items: ["0.0"], acknowledgedExtreme: nil)

        let reply = await store.runRemoteClean(request: request)

        XCTAssertEqual(reply.status, 200)
        XCTAssertTrue(files.trashed.isEmpty)
        XCTAssertTrue(history.allRecords().isEmpty, "a clean that removed nothing leaves no row")
    }

    func testACleanFromTheWrongOrAnUnknownScanTouchesNothing() async throws {
        let ready = try await scanReady()
        let files = RecordingFileManager()
        store.remoteCleanerFactory = { DiskCleaner(fileManager: files, makeSnapshot: { (true, "snap") }) }

        let wrong = await store.runRemoteClean(request: CompanionCleanRequest(scanId: "someone-elses", tier: "standard", items: ["0.0"]))
        XCTAssertEqual(wrong.status, 409)
        let invented = await store.runRemoteClean(request: CompanionCleanRequest(scanId: ready.scanId, tier: "standard", items: ["0.0", "/Users/jay/Documents"]))
        XCTAssertEqual(invented.status, 400)
        XCTAssertTrue(files.trashed.isEmpty)
        // The refused requests did not spend the scan.
        XCTAssertEqual(try report(of: store.remoteCleanReportReply()).state, "ready")
    }

    func testExtremeNeedsTheAcknowledgementAtCleanTimeToo() async throws {
        let ready = try await scanReady(tier: "extreme", acknowledged: true)
        XCTAssertEqual(ready.tier, "extreme")
        let files = RecordingFileManager()
        store.remoteCleanerFactory = { DiskCleaner(fileManager: files, makeSnapshot: { (true, "snap") }) }

        let unacknowledged = await store.runRemoteClean(request: CompanionCleanRequest(scanId: ready.scanId, tier: "extreme", items: ["0.0"], acknowledgedExtreme: false))
        XCTAssertEqual(unacknowledged.status, 400)
        XCTAssertTrue(files.trashed.isEmpty)

        let acknowledged = await store.runRemoteClean(request: CompanionCleanRequest(scanId: ready.scanId, tier: "extreme", items: ["0.0"], acknowledgedExtreme: true))
        XCTAssertEqual(acknowledged.status, 200)
        XCTAssertEqual(files.trashed.count, 1)
        XCTAssertEqual(history.allRecords().first?.tier, .extreme)
    }

    func testAnOlderPhonesBareCleanIsStillTheStandardCleanAndIsRecordedToo() async throws {
        let files = RecordingFileManager()
        store.remoteScanner = { tier, _ in
            XCTAssertEqual(tier, .standard)
            return CleanerFixtures.sampleReport(tier: tier)
        }
        store.remoteCleanerFactory = { DiskCleaner(fileManager: files, makeSnapshot: { (true, "snap") }) }

        let reply = await store.runRemoteClean(request: nil)

        XCTAssertEqual(reply.status, 200)
        // Default selection: the ticked caches, not the unticked one and not the AI artifact.
        XCTAssertEqual(Set(files.trashed), [CleanerFixtures.home + "/Library/Caches/TestCacheBig", CleanerFixtures.home + "/Library/Caches/TestCacheSmall"])
        XCTAssertEqual(history.allRecords().count, 1)
        XCTAssertEqual(history.allRecords().first?.source, "iPhone")
    }

    func testTurningSharingOffForgetsTheScan() async throws {
        _ = try await scanReady()
        // Setting the switch runs the same sync a toggle in Settings does; it is
        // off in a fresh store, so this takes the "stop sharing" branch.
        store.shareWithIPhone = false
        XCTAssertEqual(try report(of: store.remoteCleanReportReply()).state, "idle", "a scan lists paths on this Mac, so it goes when sharing does")
    }

    func testAnExpiredScanReadsAsIdle() async throws {
        _ = try await scanReady()
        let later = Date().addingTimeInterval(CompanionCleanerReport.scanLifetime + 5)
        XCTAssertEqual(try report(of: store.remoteCleanReportReply(now: later)).state, "idle")
    }
}
