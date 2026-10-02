import XCTest

@testable import HogHunter

/// Covers `HistoryStore`: recording, the window-aggregate math, memoization,
/// coverage, pruning, and the v1-to-v2 migration.  Every store here is
/// in-memory or a scratch file under `impl-tests/`; none of this ever opens
/// the installed app's `~/Library/Application Support/HogHunter/history.sqlite`.
final class HistoryStoreTests: XCTestCase {

    private func sample(
        pid: pid_t,
        start: UInt64 = 0,
        name: String = "proc",
        cpu: Double = 0,
        memory: UInt64 = 0
    ) -> ProcessSample {
        ProcessSample(
            key: ProcessKey(pid: pid, startTime: start),
            ppid: 1,
            uid: 501,
            name: name,
            path: "",
            cpuPercent: cpu,
            hasBaseline: true,
            footprintBytes: memory,
            residentBytes: memory,
            threadCount: 1,
            diskReadBytesPerSec: 0,
            diskWriteBytesPerSec: 0,
            idleWakeupsPerSec: 0
        )
    }

    private func aggregate(_ aggregates: [HistoryStore.Aggregate], pid: pid_t, start: UInt64 = 1) -> HistoryStore.Aggregate? {
        aggregates.first { $0.key == "\(pid)-\(start)" }
    }

    private func fingerprint(_ aggregates: [HistoryStore.Aggregate]) -> [String] {
        aggregates.map {
            "\($0.key)|\($0.avgCpu)|\($0.avgMemoryBytes)|\($0.peakMemoryBytes)|\($0.peakCpu)|\($0.sampleCount)|\($0.windowTicks)"
        }
    }

    // MARK: - Recording and window averages

    func testAverageDividesByWindowTickCountNotAppearanceCount() {
        let store = HistoryStore(inMemory: true)
        let t0 = Date()
        let t1 = t0.addingTimeInterval(15)

        let steady = sample(pid: 10, start: 111, name: "Steady", cpu: 100, memory: 500_000)
        let lateArriving = sample(pid: 20, start: 222, name: "Late", cpu: 100, memory: 1_000_000)

        store.record(samples: [steady], groupKey: { $0.name }, bundleId: { _ in nil }, coreCount: 4, at: t0)
        store.record(samples: [steady, lateArriving], groupKey: { $0.name }, bundleId: { _ in nil }, coreCount: 4, at: t1)

        let results = store.aggregates(lookback: 3600, groupByApp: false, sort: .cpu)

        let late = try! XCTUnwrap(aggregate(results, pid: 20, start: 222))
        XCTAssertEqual(late.windowTicks, 2)
        XCTAssertEqual(late.sampleCount, 1)
        // Present at 100% in one of two ticks: (100 + 0) / 2 = 50%.
        XCTAssertEqual(late.avgCpu, 50, accuracy: 0.0001)
        XCTAssertEqual(late.presence, 0.5, accuracy: 0.0001)

        let always = try! XCTUnwrap(aggregate(results, pid: 10, start: 111))
        XCTAssertEqual(always.windowTicks, 2)
        XCTAssertEqual(always.sampleCount, 2)
        XCTAssertEqual(always.avgCpu, 100, accuracy: 0.0001)
        XCTAssertEqual(always.presence, 1.0, accuracy: 0.0001)
    }

    func testPeakMemoryIsTheMaxAcrossTicks() {
        let store = HistoryStore(inMemory: true)
        let t0 = Date()
        let t1 = t0.addingTimeInterval(15)

        let tick0 = sample(pid: 30, start: 333, name: "Grower", cpu: 10, memory: 500_000)
        let tick1 = sample(pid: 30, start: 333, name: "Grower", cpu: 10, memory: 900_000)

        store.record(samples: [tick0], groupKey: { $0.name }, bundleId: { _ in nil }, coreCount: 4, at: t0)
        store.record(samples: [tick1], groupKey: { $0.name }, bundleId: { _ in nil }, coreCount: 4, at: t1)

        let results = store.aggregates(lookback: 3600, groupByApp: false, sort: .cpu)
        let grower = try! XCTUnwrap(aggregate(results, pid: 30, start: 333))

        XCTAssertEqual(grower.peakMemoryBytes, 900_000)
        XCTAssertEqual(grower.avgMemoryBytes, 700_000, accuracy: 0.0001)
    }

    func testSortByMemoryOrdersByAverageMemoryNotCpu() {
        let store = HistoryStore(inMemory: true)
        let t0 = Date()

        let highCpuLowMemory = sample(pid: 40, start: 1, name: "HighCPU", cpu: 200, memory: 100_000)
        let lowCpuHighMemory = sample(pid: 41, start: 1, name: "HighMem", cpu: 10, memory: 5_000_000)

        store.record(
            samples: [highCpuLowMemory, lowCpuHighMemory],
            groupKey: { $0.name },
            bundleId: { _ in nil },
            coreCount: 4,
            at: t0
        )

        let byCpu = store.aggregates(lookback: 3600, groupByApp: false, sort: .cpu)
        XCTAssertEqual(byCpu.first?.key, "40-1")

        let byMemory = store.aggregates(lookback: 3600, groupByApp: false, sort: .memory)
        XCTAssertEqual(byMemory.first?.key, "41-1")
    }

    func testAppsGroupingSumsHelpersWithTheSameGroupKeyWithinATick() {
        let store = HistoryStore(inMemory: true)
        let t0 = Date()

        let helper1 = sample(pid: 50, start: 1, name: "Chrome Helper", cpu: 20, memory: 1_000_000)
        let helper2 = sample(pid: 51, start: 1, name: "Chrome Helper (Renderer)", cpu: 15, memory: 2_000_000)

        store.record(
            samples: [helper1, helper2],
            groupKey: { _ in "app:com.google.Chrome" },
            bundleId: { _ in "com.google.Chrome" },
            coreCount: 4,
            at: t0
        )

        let results = store.aggregates(lookback: 3600, groupByApp: true, sort: .cpu)
        let chrome = try! XCTUnwrap(results.first { $0.key == "app:com.google.Chrome" })

        XCTAssertEqual(chrome.windowTicks, 1)
        XCTAssertEqual(chrome.sampleCount, 1, "the two helpers collapse into one per_ts row for their shared group_key")
        XCTAssertEqual(chrome.avgCpu, 35, accuracy: 0.0001)
        XCTAssertEqual(chrome.avgMemoryBytes, 3_000_000, accuracy: 0.0001)
    }

    // MARK: - Memoization

    func testAggregatesAreMemoizedUntilANewRecord() {
        let store = HistoryStore(inMemory: true)
        let t0 = Date()
        let s = sample(pid: 60, start: 1, name: "Memo", cpu: 10, memory: 100_000)

        store.record(samples: [s], groupKey: { $0.name }, bundleId: { _ in nil }, coreCount: 4, at: t0)

        let first = store.aggregates(lookback: 3600, groupByApp: false, sort: .cpu)
        let second = store.aggregates(lookback: 3600, groupByApp: false, sort: .cpu)
        XCTAssertEqual(fingerprint(first), fingerprint(second))

        store.record(samples: [s], groupKey: { $0.name }, bundleId: { _ in nil }, coreCount: 4, at: t0.addingTimeInterval(15))
        let third = store.aggregates(lookback: 3600, groupByApp: false, sort: .cpu)
        XCTAssertNotEqual(fingerprint(first), fingerprint(third))
    }

    // MARK: - Coverage

    func testCoverageReportsTickCountTimesSecondsPerTick() {
        let store = HistoryStore(inMemory: true)
        let t0 = Date()
        let s = sample(pid: 70, start: 1, name: "Coverage", cpu: 5, memory: 1)

        store.record(samples: [s], groupKey: { $0.name }, bundleId: { _ in nil }, coreCount: 4, at: t0)
        store.record(samples: [s], groupKey: { $0.name }, bundleId: { _ in nil }, coreCount: 4, at: t0.addingTimeInterval(5))
        store.record(samples: [s], groupKey: { $0.name }, bundleId: { _ in nil }, coreCount: 4, at: t0.addingTimeInterval(10))

        let coverage = store.coverage(lookback: 3600, secondsPerTick: 3)
        XCTAssertEqual(coverage.tickCount, 3)
        XCTAssertEqual(coverage.sampledSeconds, 9, accuracy: 0.0001)
        let first = try! XCTUnwrap(coverage.firstTimestamp)
        XCTAssertEqual(first.timeIntervalSince1970, t0.timeIntervalSince1970, accuracy: 1.0)
    }

    func testCoverageNeverClaimsMoreTimeThanTheWindowHolds() {
        let store = HistoryStore(inMemory: true)
        let t0 = Date()
        let s = sample(pid: 71, start: 1, name: "Coverage", cpu: 5, memory: 1)

        store.record(samples: [s], groupKey: { $0.name }, bundleId: { _ in nil }, coreCount: 4, at: t0)
        store.record(samples: [s], groupKey: { $0.name }, bundleId: { _ in nil }, coreCount: 4, at: t0.addingTimeInterval(5))

        // Ticks recorded at one cadence and read back at a slower one would
        // otherwise report more sampled time than the window contains.
        let coverage = store.coverage(lookback: 30, secondsPerTick: 25)
        XCTAssertEqual(coverage.sampledSeconds, 30, accuracy: 0.0001)
    }

    // MARK: - Pruning

    func testPruneRemovesRowsOlderThanTheRetentionWindow() {
        let store = HistoryStore(inMemory: true)
        let now = Date()
        let old = now.addingTimeInterval(-25 * 3600)
        let s = sample(pid: 80, start: 1, name: "Prune", cpu: 5, memory: 1)

        store.record(samples: [s], groupKey: { $0.name }, bundleId: { _ in nil }, coreCount: 4, at: old)
        store.record(samples: [s], groupKey: { $0.name }, bundleId: { _ in nil }, coreCount: 4, at: now)

        // `force: true` bypasses the 20-minute throttle so the test does not
        // have to wait for it.
        store.prune(olderThan: 24 * 3600, force: true)

        let coverage = store.coverage(lookback: 48 * 3600, secondsPerTick: 1)
        XCTAssertEqual(coverage.tickCount, 1, "only the recent tick should survive a 24h prune")
    }

    // MARK: - Same-second ticks

    func testTwoRecordsInOneSecondReplaceRatherThanAccumulate() {
        let store = HistoryStore(inMemory: true)
        let t0 = Date()
        let hog = sample(pid: 90, start: 1, name: "Dup", cpu: 100, memory: 500_000)

        // `ts` has one-second resolution and `ticks` is keyed on it, so a
        // second record inside the same second used to double that timestamp's
        // sums while the divisor stayed at one.
        store.record(samples: [hog], groupKey: { $0.name }, bundleId: { _ in nil }, coreCount: 4, at: t0)
        store.record(samples: [hog], groupKey: { $0.name }, bundleId: { _ in nil }, coreCount: 4, at: t0)

        let results = store.aggregates(lookback: 3600, groupByApp: false, sort: .cpu)
        let row = try! XCTUnwrap(aggregate(results, pid: 90, start: 1))
        XCTAssertEqual(row.avgCpu, 100, accuracy: 0.0001)
        XCTAssertEqual(row.peakCpu, 100, accuracy: 0.0001)
        XCTAssertEqual(row.avgMemoryBytes, 500_000, accuracy: 0.5)
        XCTAssertEqual(row.peakMemoryBytes, 500_000)
        XCTAssertEqual(row.sampleCount, 1)
        XCTAssertEqual(row.windowTicks, 1)
    }

    // MARK: - Error reporting

    func testAFailureToOpenSurvivesLaterCalls() {
        // A path no directory can be created for, so `sqlite3_open` fails.
        let store = HistoryStore(url: URL(fileURLWithPath: "/dev/null/hoghunter/history.sqlite"))
        store.openIfNeeded()
        XCTAssertNotNil(store.lastError, "an unopenable database must say so")

        _ = store.aggregates(lookback: 3600, groupByApp: false, sort: .cpu)
        _ = store.coverage(lookback: 3600, secondsPerTick: 3)
        XCTAssertNotNil(store.lastError, "the open failure never stops being true")
    }

    func testLastErrorClearsOnceQueriesWorkAgain() throws {
        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HogHunterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDir) }
        let dbURL = scratchDir.appendingPathComponent("recovery.sqlite")

        let store = HistoryStore(url: dbURL)
        store.record(
            samples: [sample(pid: 95, start: 1, name: "Recover", cpu: 10, memory: 1000)],
            groupKey: { $0.name },
            bundleId: { _ in nil },
            coreCount: 4
        )
        XCTAssertNil(store.lastError)

        // Pull the table out from under the open connection.
        try runSQLite(at: dbURL.path, sql: "DROP TABLE samples;")
        _ = store.aggregates(lookback: 3600, groupByApp: false, sort: .cpu)
        XCTAssertNotNil(store.lastError, "a query against a missing table must be reported")

        try runSQLite(
            at: dbURL.path,
            sql: """
            CREATE TABLE samples (ts INTEGER NOT NULL, pid INTEGER NOT NULL, start INTEGER NOT NULL,
              key TEXT NOT NULL, group_key TEXT NOT NULL, name TEXT NOT NULL, bundle TEXT,
              cpu REAL NOT NULL, mem INTEGER NOT NULL, reason INTEGER NOT NULL);
            """
        )
        _ = store.aggregates(lookback: 3600, groupByApp: false, sort: .cpu)
        XCTAssertNil(store.lastError, "a stale failure must not sit in the panel once queries work again")
    }

    func testAFailedInsertRollsBackInsteadOfPartiallyCommitting() throws {
        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HogHunterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDir) }
        let dbURL = scratchDir.appendingPathComponent("rollback.sqlite")

        let store = HistoryStore(url: dbURL)
        store.record(
            samples: [sample(pid: 60, start: 1, name: "Before", cpu: 5, memory: 100)],
            groupKey: { $0.name },
            bundleId: { _ in nil },
            coreCount: 4,
            at: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertNil(store.lastError)
        let ticksBefore = try runSQLite(at: dbURL.path, sql: "SELECT COUNT(*) FROM ticks;").trimmed

        // Pull `samples` out from under the open connection, so the next
        // `record` fails partway through its transaction -- on the very first
        // statement, `DELETE FROM samples WHERE ts = ?`, which cannot even be
        // prepared without the table.
        try runSQLite(at: dbURL.path, sql: "DROP TABLE samples;")

        store.record(
            samples: [sample(pid: 61, start: 2, name: "After", cpu: 6, memory: 200)],
            groupKey: { $0.name },
            bundleId: { _ in nil },
            coreCount: 4,
            at: Date(timeIntervalSince1970: 2_000)
        )
        XCTAssertNotNil(store.lastError, "a failed insert must be reported")

        // Before the fix, `COMMIT` ran unconditionally: the `ticks` insert
        // that precedes the (impossible) `samples` insert would have
        // committed on its own, leaving an orphaned tick with no sample rows
        // that nothing would ever revisit.  A real rollback means the tick
        // count here is unchanged.
        let ticksAfter = try runSQLite(at: dbURL.path, sql: "SELECT COUNT(*) FROM ticks;").trimmed
        XCTAssertEqual(ticksAfter, ticksBefore, "a failed insert must roll back the whole tick, not just skip the failing statement")
    }

    // MARK: - Migration

    func testV1DatabaseMigratesToCurrentSchema() throws {
        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HogHunterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDir) }
        let dbURL = scratchDir.appendingPathComponent("migration.sqlite")

        // Seed a v1-shaped database: an old `samples` table with none of the
        // v2 columns, and the default user_version of 0.  v1 stored raw mach
        // ticks read as nanoseconds, so its rows were never worth migrating —
        // the implementation drops the table rather than converting it.
        try runSQLite(
            at: dbURL.path,
            sql: "CREATE TABLE samples (pid INTEGER, cpu REAL, ts INTEGER); INSERT INTO samples VALUES (1, 12.3, 1000);"
        )
        XCTAssertEqual(try runSQLite(at: dbURL.path, sql: "PRAGMA user_version;").trimmed, "0")

        // The store opens lazily, on whichever queue asks first, so that the
        // app does not migrate on the main actor during scene construction.
        // Nothing here goes through a normal entry point, so ask explicitly.
        var store: HistoryStore? = HistoryStore(url: dbURL)
        store?.openIfNeeded()
        XCTAssertNil(store?.lastError)
        store = nil  // Closes the connection so a fresh process can reopen the file.

        let version = try runSQLite(at: dbURL.path, sql: "PRAGMA user_version;").trimmed
        XCTAssertEqual(version, "3")

        let schema = try runSQLite(at: dbURL.path, sql: "PRAGMA table_info(samples);")
        for column in ["ts", "pid", "start", "key", "group_key", "name", "bundle", "cpu", "mem", "reason"] {
            XCTAssertTrue(schema.contains(column), "expected column '\(column)' in migrated schema:\n\(schema)")
        }

        // v3 added the network counters, so an upgraded database has them too --
        // the Network tab's 24-hour peak reads this table.
        let net = try runSQLite(at: dbURL.path, sql: "PRAGMA table_info(net_samples);")
        for column in ["ts", "bytes_in", "bytes_out"] {
            XCTAssertTrue(net.contains(column), "expected net_samples column '\(column)' in migrated schema:\n\(net)")
        }
    }
}

// MARK: - sqlite3 CLI helper

/// Shells out to the system `sqlite3` binary instead of linking the SQLite3
/// module directly into the test target, so this file's migration check does
/// not depend on the test bundle's own linker settings — only on a tool that
/// ships with macOS.
@discardableResult
private func runSQLite(at path: String, sql: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [path, sql]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
