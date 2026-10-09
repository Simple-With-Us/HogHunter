import XCTest
@testable import HogHunter

final class CleanupHistoryStoreTests: XCTestCase {
    var store: CleanupHistoryStore!
    var tempURL: URL!

    override func setUp() {
        super.setUp()
        // Each test gets its own file under /tmp so a failure in one test
        // cannot leak records into another.
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HogHunterCleanupHistoryTests-\(UUID().uuidString).jsonl")
        store = CleanupHistoryStore(url: tempURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    func testEmptyStoreReturnsNilLatest() {
        XCTAssertNil(store.latestRecord())
        XCTAssertEqual(store.allRecords(), [])
    }

    func testAppendCreatesFileAndRoundTripsRecord() throws {
        let record = CleanupHistoryRecord(
            bytesReclaimed: 47 * 1024 * 1024 * 1024,
            itemsRemoved: 3,
            tier: .standard,
            categoryIds: ["apfsSnapshots", "developer"],
            itemTitles: ["com.apple.TimeMachine.2026-10-05-062128.local", "Xcode DerivedData", "iOS Simulator Devices"],
            snapshotName: "snap-2026-10-05-120000",
            cleanedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )
        store.append(record)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))
        let latest = try XCTUnwrap(store.latestRecord())
        XCTAssertEqual(latest, record)
    }

    func testAppendKeepsMultipleRecordsNewestFirst() {
        let older = CleanupHistoryRecord(
            bytesReclaimed: 1_000,
            itemsRemoved: 1,
            tier: .standard,
            categoryIds: ["userCaches"],
            itemTitles: ["old"],
            snapshotName: nil,
            cleanedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )
        let newer = CleanupHistoryRecord(
            bytesReclaimed: 2_000,
            itemsRemoved: 2,
            tier: .extreme,
            categoryIds: ["aiArtifacts"],
            itemTitles: ["newer"],
            snapshotName: "snap-2",
            cleanedAt: Date(timeIntervalSince1970: 1_760_000_500)
        )
        store.append(older)
        store.append(newer)

        let records = store.allRecords()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first, newer, "Newest record must be first")
        XCTAssertEqual(records.last, older)
    }

    func testCorruptLinesAreSkippedNotRaised() throws {
        // A real on-disk log can get a half-written line if the power goes
        // mid-append.  The panel must keep rendering the records that did
        // survive, never throw, never silently drop everything.
        let good = CleanupHistoryRecord(
            bytesReclaimed: 1_000,
            itemsRemoved: 1,
            tier: .standard,
            categoryIds: ["userCaches"],
            itemTitles: ["ok"],
            snapshotName: nil,
            cleanedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )
        store.append(good)

        // Append a line of garbage that JSONDecoder will reject, then a
        // second valid record.
        let garbage = Data("{not json\n".utf8)
        let handle = try FileHandle(forWritingTo: tempURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: garbage)
        try handle.close()

        let second = CleanupHistoryRecord(
            bytesReclaimed: 2_000,
            itemsRemoved: 2,
            tier: .standard,
            categoryIds: ["developer"],
            itemTitles: ["second"],
            snapshotName: nil,
            cleanedAt: Date(timeIntervalSince1970: 1_760_001_000)
        )
        store.append(second)

        let records = store.allRecords()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.bytesReclaimed), [2_000, 1_000])
    }

    func testRelativeDateBuckets() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        XCTAssertEqual(CleanupHistoryStore.relativeDate(for: now.addingTimeInterval(-5), now: now), "just now")
        XCTAssertEqual(CleanupHistoryStore.relativeDate(for: now.addingTimeInterval(-65), now: now), "1 minute ago")
        XCTAssertEqual(CleanupHistoryStore.relativeDate(for: now.addingTimeInterval(-30 * 60), now: now), "30 minutes ago")
        XCTAssertEqual(CleanupHistoryStore.relativeDate(for: now.addingTimeInterval(-65 * 60), now: now), "1 hour ago")
        XCTAssertEqual(CleanupHistoryStore.relativeDate(for: now.addingTimeInterval(-5 * 3600), now: now), "5 hours ago")
        XCTAssertEqual(CleanupHistoryStore.relativeDate(for: now.addingTimeInterval(-25 * 3600), now: now), "yesterday")
        XCTAssertEqual(CleanupHistoryStore.relativeDate(for: now.addingTimeInterval(-3 * 86_400), now: now), "3 days ago")
    }

    func testFormattedBytesReclaimedUsesHogFormat() {
        let record = CleanupHistoryRecord(
            bytesReclaimed: 1_500_000_000,
            itemsRemoved: 1,
            tier: .standard,
            categoryIds: ["userCaches"],
            itemTitles: ["x"],
            snapshotName: nil
        )
        // HogFormat.memory rounds 1,500,000,000 bytes to "1.4 GB".
        XCTAssertEqual(record.formattedBytesReclaimed, "1.4 GB")
    }

    func testConcurrentFirstAppendsDoNotClobber() {
        // Two threads racing the missing-file branch must both survive; the
        // lock + create-then-append path is the contract behind "Safe to call
        // from any thread".
        let group = DispatchGroup()
        let count = 20
        for i in 0..<count {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let record = CleanupHistoryRecord(
                    bytesReclaimed: UInt64(i),
                    itemsRemoved: 1,
                    tier: .standard,
                    categoryIds: ["userCaches"],
                    itemTitles: ["t\(i)"],
                    snapshotName: nil,
                    cleanedAt: Date(timeIntervalSince1970: 1_760_000_000 + TimeInterval(i))
                )
                self.store.append(record)
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(store.allRecords().count, count)
    }

    func testLatestRecordReadsTailWithoutNeedingFullSort() {
        for i in 0..<5 {
            store.append(CleanupHistoryRecord(
                bytesReclaimed: UInt64(i),
                itemsRemoved: 1,
                tier: .standard,
                categoryIds: ["userCaches"],
                itemTitles: ["t\(i)"],
                snapshotName: nil,
                cleanedAt: Date(timeIntervalSince1970: 1_760_000_000 + TimeInterval(i))
            ))
        }
        XCTAssertEqual(store.latestRecord()?.bytesReclaimed, 4)
    }
}