import Darwin
import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A rolling 24 hours of the heaviest processes, one row per recorded tick.
///
/// Schema v2 keeps a `ticks` table beside `samples` so an average can be taken
/// over the window's whole length rather than over the rows that happen to
/// exist: a process seen in 3 of 120 ticks should read as a small average, not
/// as its own busy moments.  Schema v3 adds `net_samples`, one cumulative
/// interface-counter reading per sample, which is what lets the Network tab
/// show a 24-hour bandwidth peak instead of only the last few seconds.  The
/// database URL is always explicit so tests and command-line checks never
/// touch the installed app's file.
///
/// `@unchecked Sendable` is honest here: every entry point serializes on the
/// same lock, and the database is opened lazily inside that lock by whichever
/// call comes first -- never on the main actor while the scene is being built.
final class HistoryStore: @unchecked Sendable {
    struct Aggregate {
        var key: String
        var name: String
        var bundleId: String?
        /// Average over every tick in the window, not only the ticks the
        /// process appeared in.
        var avgCpu: Double
        var avgMemoryBytes: Double
        var peakMemoryBytes: UInt64
        var peakCpu: Double
        var sampleCount: Int
        var windowTicks: Int

        /// Fraction of the window's ticks in which this key appeared, 0-1.
        var presence: Double {
            guard windowTicks > 0 else { return 0 }
            return min(1, Double(sampleCount) / Double(windowTicks))
        }
    }

    struct Coverage {
        var tickCount: Int
        var sampledSeconds: TimeInterval
        var firstTimestamp: Date?
    }

    /// One stored interface-counter reading: a timestamp and the lifetime byte
    /// counters as of that moment.
    struct NetworkReading: Equatable {
        var ts: Int64
        var bytesIn: UInt64
        var bytesOut: UInt64
    }

    /// Why a row was kept, as a bit field.
    enum Reason {
        static let cpu = 1
        static let memory = 2
    }

    private struct MemoKey: Hashable {
        var lookback: TimeInterval
        var groupByApp: Bool
        var sort: HogSort
        var ascending: Bool
        var lastTs: Int64
    }

    private let path: String
    private var db: OpaquePointer?
    private var didOpen = false
    /// Set once, inside `openLocked`, the moment the open sequence -- the
    /// `sqlite3_open` call, either pragma, or the migration -- hits a
    /// failure.  `openLocked` leaves `db` non-nil even when a pragma or the
    /// migration fails, so `record` and `aggregates` cannot tell a healthy
    /// connection from one that opened with an error just by checking `db`;
    /// they consult this flag instead before clearing `lastError`.
    private var openFailed = false
    private let lock = NSLock()
    private var memo: [MemoKey: [Aggregate]] = [:]
    private var lastRecordedTs: Int64 = 0
    private var lastPrune = Date.distantPast

    /// The most recent SQLite failure, for the panel to show.  Cleared at the
    /// start of `record` and of `aggregates`, which are the first call in each
    /// of the two batches the store makes -- record then prune, aggregates then
    /// coverage -- so the second call in a batch can never erase the first
    /// call's error.  A failure to open is never cleared, because it never
    /// stops being true.
    private(set) var lastError: String?

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HogHunter", isDirectory: true)
            .appendingPathComponent("history.sqlite")
    }

    init(url: URL) {
        self.path = url.path
    }

    /// An in-memory database.  Used by tests and by any check that must not
    /// touch the installed app's history.
    init(inMemory: Bool) {
        self.path = inMemory ? ":memory:" : Self.defaultURL.path
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Opening

    /// Opens, migrates and first-prunes the database if that has not happened
    /// yet.  Every entry point calls this, so it is only needed directly by a
    /// caller that wants the work to land on a particular queue -- `HogStore`
    /// primes it on the sampling queue -- or by a test that inspects the file
    /// without going through an entry point.
    func openIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        openLocked()
    }

    private func openLocked() {
        guard !didOpen else { return }
        didOpen = true
        if path != ":memory:" {
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            lastError = "Could not open the history database."
            openFailed = true
            if let handle { sqlite3_close(handle) }
            return
        }
        db = handle
        if !exec("PRAGMA journal_mode=WAL;", label: "journal mode") { openFailed = true }
        if !exec("PRAGMA synchronous=NORMAL;", label: "synchronous") { openFailed = true }
        if !migrate() { openFailed = true }
        pruneLocked()
    }

    // MARK: - Schema

    @discardableResult
    private func migrate() -> Bool {
        guard db != nil else { return false }
        var ok = true
        // A failed read must not be taken for version 0: that would drop a
        // perfectly good v2 `samples` table.
        if let version = scalarInt("PRAGMA user_version") {
            if version < 2 {
                // v1 stored raw mach ticks read as nanoseconds, so every CPU
                // value in it was 41.7x too small.  There is nothing worth
                // migrating.
                if !exec("DROP TABLE IF EXISTS samples;", label: "drop v1 samples") { ok = false }
                if !exec("DROP INDEX IF EXISTS samples_ts;", label: "drop v1 index") { ok = false }
            }
        } else {
            ok = false
        }
        if !exec(
            """
            CREATE TABLE IF NOT EXISTS ticks (ts INTEGER PRIMARY KEY);
            CREATE TABLE IF NOT EXISTS samples (
              ts INTEGER NOT NULL,
              pid INTEGER NOT NULL,
              start INTEGER NOT NULL,
              key TEXT NOT NULL,
              group_key TEXT NOT NULL,
              name TEXT NOT NULL,
              bundle TEXT,
              cpu REAL NOT NULL,
              mem INTEGER NOT NULL,
              reason INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS samples_ts ON samples(ts);
            CREATE TABLE IF NOT EXISTS net_samples (
              ts INTEGER PRIMARY KEY,
              bytes_in INTEGER NOT NULL,
              bytes_out INTEGER NOT NULL
            );
            """,
            label: "create v3 schema"
        ) {
            ok = false
        }
        if !exec("PRAGMA user_version=3;", label: "set user version") { ok = false }
        return ok
    }

    // MARK: - Network

    /// Records one cumulative interface-counter reading.  The columns are
    /// lifetime byte counters, not rates, so this row is only meaningful next
    /// to its neighbours -- the same reason `ticks` exists beside `samples`.
    /// `ts` is the primary key, so a second reading inside one second replaces
    /// the first instead of stacking a second row for the same instant.
    func recordNetwork(bytesIn: UInt64, bytesOut: UInt64, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        openLocked()
        guard let db else { return }
        if !openFailed { lastError = nil }

        let ts = Int64(date.timeIntervalSince1970)
        var statement: OpaquePointer?
        guard check(
            sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO net_samples(ts,bytes_in,bytes_out) VALUES(?,?,?)", -1, &statement, nil),
            "prepare net sample"
        ) else {
            sqlite3_finalize(statement)
            return
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, ts)
        sqlite3_bind_int64(statement, 2, Int64(bitPattern: bytesIn))
        sqlite3_bind_int64(statement, 3, Int64(bitPattern: bytesOut))
        if !check(sqlite3_step(statement), "insert net sample", expected: SQLITE_DONE) {
            return
        }
    }

    /// The newest interface-counter reading, or nil when nothing was ever
    /// recorded.  `BandwidthTracker` uses it to keep showing a live rate when
    /// the app was restarted mid-window.
    func latestNetworkSample() -> NetworkReading? {
        lock.lock()
        defer { lock.unlock() }
        openLocked()
        guard let db else { return nil }
        var statement: OpaquePointer?
        let sql = "SELECT ts, bytes_in, bytes_out FROM net_samples ORDER BY ts DESC LIMIT 1"
        guard check(sqlite3_prepare_v2(db, sql, -1, &statement, nil), "prepare latest net sample") else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return NetworkReading(
            ts: Int64(sqlite3_column_int64(statement, 0)),
            bytesIn: UInt64(bitPattern: sqlite3_column_int64(statement, 1)),
            bytesOut: UInt64(bitPattern: sqlite3_column_int64(statement, 2))
        )
    }

    /// Peak and total traffic over `lookback`.
    ///
    /// Counters are cumulative and monotonic, so a rate is the difference
    /// between two readings divided by the time between them.  Rows are folded
    /// into one-minute buckets first (`MAX` of a monotonic counter is its
    /// last value in the bucket) so a 24-hour query returns ~1,400 rows rather
    /// than ~17,000, and a sampling gap cannot inflate a rate: the divisor is
    /// the gap's real length, never an assumed tick interval.
    func networkPeaks(lookback: TimeInterval = 24 * 60 * 60, now: Date = Date()) -> NetworkPeaks {
        lock.lock()
        defer { lock.unlock() }
        openLocked()
        guard let db else { return .empty }
        let cutoff = Int64(now.timeIntervalSince1970 - lookback)
        var statement: OpaquePointer?
        let sql = """
        SELECT CAST(ts / 60 AS INTEGER) AS bucket, MAX(bytes_in), MAX(bytes_out)
        FROM net_samples WHERE ts >= ? GROUP BY bucket ORDER BY bucket
        """
        guard check(sqlite3_prepare_v2(db, sql, -1, &statement, nil), "prepare net peaks") else {
            sqlite3_finalize(statement)
            return .empty
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, cutoff)

        struct Bucket {
            var at: TimeInterval
            var bytesIn: UInt64
            var bytesOut: UInt64
        }
        var buckets: [Bucket] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            buckets.append(Bucket(
                at: Double(sqlite3_column_int64(statement, 0)) * 60,
                bytesIn: UInt64(bitPattern: sqlite3_column_int64(statement, 1)),
                bytesOut: UInt64(bitPattern: sqlite3_column_int64(statement, 2))
            ))
        }
        guard !buckets.isEmpty else { return .empty }

        // A counter that went backwards between buckets means an interface was
        // re-created.  That segment is skipped rather than divided: it is not
        // a burst of traffic, and a negative delta would be a negative rate.
        var peakDown: Double = 0
        var peakUp: Double = 0
        var peakAt: Date?
        var totalDown: UInt64 = 0
        var totalUp: UInt64 = 0
        for (previous, next) in zip(buckets, buckets.dropFirst()) {
            let seconds = next.at - previous.at
            guard seconds > 0, next.bytesIn >= previous.bytesIn, next.bytesOut >= previous.bytesOut else { continue }
            let down = Double(next.bytesIn - previous.bytesIn) / seconds
            let up = Double(next.bytesOut - previous.bytesOut) / seconds
            totalDown += next.bytesIn - previous.bytesIn
            totalUp += next.bytesOut - previous.bytesOut
            // Strictly greater keeps the earliest peak of an equal pair, so the
            // timestamp says when the high-water mark was first reached.
            if down > peakDown { peakDown = down; peakAt = Date(timeIntervalSince1970: next.at) }
            if up > peakUp { peakUp = up; peakAt = peakAt ?? Date(timeIntervalSince1970: next.at) }
        }

        let sampledSeconds = (buckets.last!.at - buckets.first!.at)
        return NetworkPeaks(
            peakDownBytesPerSecond: peakDown,
            peakUpBytesPerSecond: peakUp,
            peakAt: peakAt,
            totalDownBytes: totalDown,
            totalUpBytes: totalUp,
            sampledSeconds: sampledSeconds,
            hasSamples: buckets.count > 1
        )
    }

    // MARK: - Recording

    /// Records one tick: the union of the top 25 by CPU and the top 25 by
    /// footprint.  `reason` says which list each row came from.
    func record(
        samples: [ProcessSample],
        groupKey: (ProcessSample) -> String,
        bundleId: (ProcessSample) -> String?,
        coreCount: Int,
        at date: Date = Date()
    ) {
        lock.lock()
        defer { lock.unlock() }
        openLocked()
        guard let db else { return }
        if !openFailed { lastError = nil }

        let ceiling = CpuMath.ceiling(coreCount: coreCount)
        let byCpu = samples.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(25)
        let byMemory = samples.sorted { $0.footprintBytes > $1.footprintBytes }.prefix(25)
        var reasons: [ProcessKey: Int] = [:]
        var chosen: [ProcessKey: ProcessSample] = [:]
        for sample in byCpu {
            reasons[sample.key, default: 0] |= Reason.cpu
            chosen[sample.key] = sample
        }
        for sample in byMemory {
            reasons[sample.key, default: 0] |= Reason.memory
            chosen[sample.key] = sample
        }
        guard !chosen.isEmpty else { return }

        let ts = Int64(date.timeIntervalSince1970)
        guard check(sqlite3_exec(db, "BEGIN", nil, nil, nil), "begin") else { return }

        // Tracks the first failed statement in this transaction.  A failure
        // here must not be silently committed -- a tick row with no sample
        // rows (or vice versa) would corrupt the average forever, since
        // nothing ever revisits an old timestamp.
        var failed = false

        // `ts` is a whole second and `ticks` is keyed on it, so two ticks inside
        // one second would leave one tick row and two sets of sample rows --
        // doubling that second's sums while the divisor stayed at one.  Last
        // write wins instead; this deletes nothing on the normal path.
        var replaceStatement: OpaquePointer?
        if check(sqlite3_prepare_v2(db, "DELETE FROM samples WHERE ts = ?", -1, &replaceStatement, nil), "prepare replace") {
            sqlite3_bind_int64(replaceStatement, 1, ts)
            if !check(sqlite3_step(replaceStatement), "replace tick", expected: SQLITE_DONE) { failed = true }
        } else {
            failed = true
        }
        sqlite3_finalize(replaceStatement)

        if !failed {
            var tickStatement: OpaquePointer?
            if check(sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO ticks(ts) VALUES(?)", -1, &tickStatement, nil), "prepare tick") {
                sqlite3_bind_int64(tickStatement, 1, ts)
                if !check(sqlite3_step(tickStatement), "insert tick", expected: SQLITE_DONE) { failed = true }
            } else {
                failed = true
            }
            sqlite3_finalize(tickStatement)
        }

        if !failed {
            var statement: OpaquePointer?
            let sql = """
            INSERT INTO samples(ts,pid,start,key,group_key,name,bundle,cpu,mem,reason)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            """
            if check(sqlite3_prepare_v2(db, sql, -1, &statement, nil), "prepare sample") {
                for (identity, sample) in chosen {
                    guard !failed else { break }
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    sqlite3_bind_int64(statement, 1, ts)
                    sqlite3_bind_int(statement, 2, identity.pid)
                    sqlite3_bind_int64(statement, 3, Int64(bitPattern: identity.startTime))
                    sqlite3_bind_text(statement, 4, "\(identity.pid)-\(identity.startTime)", -1, sqliteTransient)
                    sqlite3_bind_text(statement, 5, groupKey(sample), -1, sqliteTransient)
                    sqlite3_bind_text(statement, 6, sample.name, -1, sqliteTransient)
                    if let bundle = bundleId(sample) {
                        sqlite3_bind_text(statement, 7, bundle, -1, sqliteTransient)
                    } else {
                        sqlite3_bind_null(statement, 7)
                    }
                    sqlite3_bind_double(statement, 8, min(max(0, sample.cpuPercent), ceiling))
                    sqlite3_bind_int64(statement, 9, Int64(bitPattern: sample.footprintBytes))
                    sqlite3_bind_int(statement, 10, Int32(reasons[identity] ?? 0))
                    if !check(sqlite3_step(statement), "insert sample", expected: SQLITE_DONE) { failed = true }
                }
            } else {
                failed = true
            }
            sqlite3_finalize(statement)
        }

        guard !failed else {
            let cause = lastError
            // A failed `BEGIN` never opened a transaction, so rolling back
            // then would discard nothing and only overwrite `cause` with a
            // spurious "cannot rollback" error.
            if sqlite3_get_autocommit(db) == 0 {
                _ = check(sqlite3_exec(db, "ROLLBACK", nil, nil, nil), "rollback")
            }
            lastError = cause ?? lastError ?? "History record failed."
            return
        }
        _ = check(sqlite3_exec(db, "COMMIT", nil, nil, nil), "commit")
        lastRecordedTs = ts
    }

    // MARK: - Reading

    /// Per-timestamp sums first, then an average over the window's tick count.
    /// Memoized on `lastRecordedTs`, so the panel may ask on every tick.
    func aggregates(lookback: TimeInterval, groupByApp: Bool, sort: HogSort, ascending: Bool = false) -> [Aggregate] {
        lock.lock()
        defer { lock.unlock() }
        openLocked()
        guard let db else { return [] }
        if !openFailed { lastError = nil }

        let memoKey = MemoKey(lookback: lookback, groupByApp: groupByApp, sort: sort, ascending: ascending, lastTs: lastRecordedTs)
        if let cached = memo[memoKey] { return cached }

        let cutoff = Int64(Date().timeIntervalSince1970 - lookback)
        let column = groupByApp ? "group_key" : "key"
        let primaryOrder = sort == .cpu ? "avg_cpu DESC, avg_mem DESC" : "avg_mem DESC, avg_cpu DESC"
        let finalDir = ascending ? "ASC" : "DESC"
        let finalOrder = sort == .cpu ? "avg_cpu \(finalDir), avg_mem \(finalDir)" : "avg_mem \(finalDir), avg_cpu \(finalDir)"
        let sql = """
        WITH win AS (SELECT COUNT(*) AS n FROM ticks WHERE ts >= ?1),
        per_ts AS (
          SELECT ts, \(column) AS k, SUM(cpu) AS cpu, SUM(mem) AS mem,
                 MIN(name) AS name, MIN(bundle) AS bundle
          FROM samples WHERE ts >= ?1 GROUP BY ts, k
        ),
        top_hogs AS (
          SELECT k, MIN(name) AS name, MIN(bundle) AS bundle,
                 SUM(cpu) * 1.0 / win.n AS avg_cpu, SUM(mem) * 1.0 / win.n AS avg_mem,
                 MAX(mem) AS max_mem, MAX(cpu) AS max_cpu, COUNT(*) AS count, win.n AS win_n
          FROM per_ts, win
          GROUP BY k
          ORDER BY \(primaryOrder)
          LIMIT 40
        )
        SELECT k, name, bundle, avg_cpu, avg_mem, max_mem, max_cpu, count, win_n
        FROM top_hogs
        ORDER BY \(finalOrder)
        """

        var statement: OpaquePointer?
        guard check(sqlite3_prepare_v2(db, sql, -1, &statement, nil), "prepare aggregates") else {
            sqlite3_finalize(statement)
            return []
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, cutoff)

        // The step code has to be captured, not compared inline: a schema that
        // changed underneath this connection surfaces as an error here, not at
        // prepare time, and "no more rows" and "the read failed" must not look
        // the same to the panel.
        var out: [Aggregate] = []
        while true {
            let code = sqlite3_step(statement)
            guard code == SQLITE_ROW else {
                _ = check(code, "read aggregates", expected: SQLITE_DONE)
                break
            }
            let windowTicks = Int(sqlite3_column_int(statement, 8))
            guard windowTicks > 0 else { continue }
            out.append(
                Aggregate(
                    key: text(statement, 0) ?? "",
                    name: text(statement, 1) ?? "",
                    bundleId: text(statement, 2),
                    avgCpu: sqlite3_column_double(statement, 3),
                    avgMemoryBytes: sqlite3_column_double(statement, 4),
                    peakMemoryBytes: UInt64(bitPattern: sqlite3_column_int64(statement, 5)),
                    peakCpu: sqlite3_column_double(statement, 6),
                    sampleCount: Int(sqlite3_column_int(statement, 7)),
                    windowTicks: windowTicks
                )
            )
        }
        memo = [memoKey: out]
        return out
    }

    /// How much of the window Hog Hunter was actually running for.  Ticks are
    /// counted at the caller's current cadence, so the answer is clamped to the
    /// window: it can be short, but it can never claim more time than the
    /// window holds.
    func coverage(lookback: TimeInterval, secondsPerTick: TimeInterval) -> Coverage {
        lock.lock()
        defer { lock.unlock() }
        openLocked()
        guard let db else { return Coverage(tickCount: 0, sampledSeconds: 0, firstTimestamp: nil) }
        let cutoff = Int64(Date().timeIntervalSince1970 - lookback)
        var statement: OpaquePointer?
        let sql = "SELECT COUNT(*), MIN(ts) FROM ticks WHERE ts >= ?"
        guard check(sqlite3_prepare_v2(db, sql, -1, &statement, nil), "prepare coverage") else {
            sqlite3_finalize(statement)
            return Coverage(tickCount: 0, sampledSeconds: 0, firstTimestamp: nil)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, cutoff)
        // A bare aggregate with no GROUP BY always returns exactly one row, so
        // an empty window arrives as a row with a count of 0.  Anything that is
        // not a row is a real failure, never "nothing recorded yet".
        let code = sqlite3_step(statement)
        guard code == SQLITE_ROW else {
            lastError = "History read coverage failed (\(code))."
            return Coverage(tickCount: 0, sampledSeconds: 0, firstTimestamp: nil)
        }
        let count = Int(sqlite3_column_int(statement, 0))
        let first = sqlite3_column_type(statement, 1) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 1)))
        return Coverage(
            tickCount: count,
            sampledSeconds: min(Double(count) * secondsPerTick, lookback),
            firstTimestamp: first
        )
    }

    /// Drops everything older than the retention window.  Safe to call often;
    /// it does real work at most every 20 minutes.
    func prune(olderThan retention: TimeInterval = 24 * 60 * 60, force: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        openLocked()
        pruneLocked(olderThan: retention, force: force)
    }

    private func pruneLocked(olderThan retention: TimeInterval = 24 * 60 * 60, force: Bool = false) {
        guard db != nil else { return }
        let now = Date()
        if !force, now.timeIntervalSince(lastPrune) < 20 * 60 { return }
        lastPrune = now
        let cutoff = Int64(now.timeIntervalSince1970 - retention)
        exec("DELETE FROM samples WHERE ts < \(cutoff); DELETE FROM ticks WHERE ts < \(cutoff); DELETE FROM net_samples WHERE ts < \(cutoff);", label: "prune")
        memo.removeAll()
    }

    // MARK: - SQLite plumbing

    @discardableResult
    private func exec(_ sql: String, label: String) -> Bool {
        guard let db else { return false }
        var message: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(db, sql, nil, nil, &message)
        if code != SQLITE_OK {
            lastError = "History \(label) failed (\(code))."
            if let message { sqlite3_free(message) }
            return false
        }
        if let message { sqlite3_free(message) }
        return true
    }

    private func check(_ code: Int32, _ label: String, expected: Int32 = SQLITE_OK) -> Bool {
        if code == expected || code == SQLITE_OK || code == SQLITE_DONE || code == SQLITE_ROW { return true }
        lastError = "History \(label) failed (\(code))."
        return false
    }

    /// Nil when the value could not be read, which the caller must not confuse
    /// with a legitimate zero.
    private func scalarInt(_ sql: String) -> Int? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        guard check(sqlite3_prepare_v2(db, sql, -1, &statement, nil), "prepare \(sql)") else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_ROW else {
            lastError = "History read \(sql) failed (\(code))."
            return nil
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: raw)
    }
}
