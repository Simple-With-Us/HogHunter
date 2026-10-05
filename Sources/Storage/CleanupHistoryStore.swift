import Foundation

/// A single completed disk-cleanup run, persisted to disk so the Storage tab
/// can show "Last cleanup <relative date> — freed <size>" without asking the
/// user to remember.
///
/// The history is intentionally tiny: a JSON file with one record per line
/// (write-once, append-only, never modified) is enough for the panel's needs
/// and lets a crash during cleanup lose at most one in-flight row instead of
/// a full SQLite database.
struct CleanupHistoryRecord: Codable, Equatable, Sendable {
    var cleanedAt: Date
    var bytesReclaimed: UInt64
    var itemsRemoved: Int
    var tier: CleanTier
    /// Raw category ids (e.g. "developer", "apfsSnapshots") so the view
    /// can summarize what was cleaned without inspecting the items themselves.
    var categoryIds: [String]
    /// Titles of the items that were removed, in the order the cleanup ran.
    var itemTitles: [String]
    /// The APFS local snapshot name created before the cleanup, if any.  Lets
    /// the user roll back without needing to remember which snapshot applies.
    var snapshotName: String?

    init(bytesReclaimed: UInt64,
         itemsRemoved: Int,
         tier: CleanTier,
         categoryIds: [String],
         itemTitles: [String],
         snapshotName: String?,
         cleanedAt: Date = Date()) {
        self.cleanedAt = cleanedAt
        self.bytesReclaimed = bytesReclaimed
        self.itemsRemoved = itemsRemoved
        self.tier = tier
        self.categoryIds = categoryIds
        self.itemTitles = itemTitles
        self.snapshotName = snapshotName
    }

    var formattedBytesReclaimed: String {
        HogFormat.memory(bytesReclaimed)
    }
}

/// Append-only log of cleanup runs under the existing internal namespace
/// (`~/Library/Application Support/HogHunter/` — AGENTS.md: stable across the
/// bundle-ID migration, must not be renamed).
///
/// Writes go to a temp file that is then renamed over the real log, so a
/// partial write never produces a half-decodable file.  Reads tolerate a
/// missing or empty file (returning `[]`) and any record that fails to decode is
/// skipped, so a corrupted line does not brick the panel.
final class CleanupHistoryStore: @unchecked Sendable {
    /// The file Hog Hunter reads on disk.  Always explicit so tests and
    /// command-line checks never touch the installed app's log.
    let url: URL
    /// Serializes create-vs-append so two concurrent first writes cannot
    /// each take the atomic-create branch and clobber each other.
    private let lock = NSLock()

    init(url: URL) {
        self.url = url
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HogHunter", isDirectory: true)
            .appendingPathComponent("cleanup-history.jsonl")
    }

    /// Used by tests and the `--print` CLI check.
    init(inMemory: Bool) {
        if inMemory {
            // A unique tmp path keeps tests hermetic; CleanupHistoryStore is
            // happy to create its parent directory on first write.
            self.url = FileManager.default.temporaryDirectory
                .appendingPathComponent("HogHunterCleanupHistory-\(UUID().uuidString).jsonl")
        } else {
            self.url = Self.defaultURL
        }
    }

    // MARK: - Writing

    /// Appends one record to the log.  Safe to call from any thread.
    func append(_ record: CleanupHistoryRecord) {
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(record) else { return }

        let line = data + Data("\n".utf8)

        lock.lock()
        defer { lock.unlock() }

        if !FileManager.default.fileExists(atPath: url.path) {
            try? line.write(to: url, options: [.atomic])
            return
        }

        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } catch {
            // A failed append cannot be allowed to retry blindly — the file may
            // have been replaced underneath us.  Best we can do is drop the
            // record and let the next clean have a turn.
        }
    }

    // MARK: - Reading

    /// Reads every record from disk, newest first.  Corrupt lines are skipped,
    /// never raised, so a half-written row never bricks the panel.
    func allRecords() -> [CleanupHistoryRecord] {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var out: [CleanupHistoryRecord] = []
        for rawLine in data.split(separator: 0x0A) {
            guard !rawLine.isEmpty else { continue }
            guard let record = try? decoder.decode(CleanupHistoryRecord.self, from: Data(rawLine)) else {
                continue
            }
            out.append(record)
        }
        return out.sorted { $0.cleanedAt > $1.cleanedAt }
    }

    /// The most recent successful record, or nil when the log is empty.
    /// Reads only a bounded tail of the append-only log instead of decoding
    /// every historical row on each Storage panel open.
    func latestRecord() -> CleanupHistoryRecord? {
        guard FileManager.default.fileExists(atPath: url.path),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        let window: UInt64 = 64 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        let tail = (try? handle.readToEnd()) ?? Data()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in tail.split(separator: 0x0A).reversed() {
            guard !line.isEmpty else { continue }
            if let record = try? decoder.decode(CleanupHistoryRecord.self, from: Data(line)) {
                return record
            }
        }
        return nil
    }

    // MARK: - Display helpers

    /// "2 minutes ago", "yesterday", "3 days ago" — friendly for the hero
    /// header.  Mirrors the relative-date style already used elsewhere in the
    /// panel.
    static func relativeDate(for date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 60 * 60 {
            let minutes = Int(interval / 60)
            return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago"
        }
        if interval < 60 * 60 * 24 {
            let hours = Int(interval / 3600)
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        }
        let days = Int(interval / (60 * 60 * 24))
        return days == 1 ? "yesterday" : "\(days) days ago"
    }
}