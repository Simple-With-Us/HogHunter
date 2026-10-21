import Foundation

/// The mkdir-based housekeeper lock, mirrored from the Python reclaim engine.
///
/// Why this exists
/// ---------------
/// `scripts/vacuum/lock.py` owns the original: it creates
/// `~/.claude-disk-janitor/.housekeeper.lock` as a *directory*, treats a lock
/// older than two hours as stale, and treats `HOUSEKEEPER_LOCK_OWNER=1` as
/// re-entrancy.  `~/apps/mac-auto-cleanup.sh` uses the same directory with the
/// same staleness rule, and the comment there says why:
///
/// > would make both children exit 0 with "peer holds lock" -- cleanup would
/// > silently never
///
/// So the lock is deliberate mutual exclusion.  The in-app regimen calls
/// `DiskCleaner` directly in Swift, which means it would otherwise reclaim
/// while a Python tick is reclaiming, and the two would fight over the same
/// files.  This is the Swift side of the same lock, so the two never run at
/// the same time.
///
/// The two implementations have to agree on the path, the staleness window,
/// the re-entrancy token, and the "only remove a lock you took" rule.
final class HousekeeperLock {
    /// Where the lock lives when nothing else is injected.
    static let defaultPath = "~/.claude-disk-janitor/.housekeeper.lock"

    /// A lock older than this was left behind by a process that died.
    static let defaultStaleMinutes: Double = 120

    /// The default lock path with `~` expanded.
    static var defaultPathURL: URL {
        URL(fileURLWithPath: (defaultPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// What an acquire attempt found.
    enum Outcome {
        /// This process holds the lock.
        case acquired
        /// Another process holds it, and it is not stale.
        case heldByPeer
    }

    private let path: URL
    private let staleInterval: TimeInterval
    private let fileManager: FileManager
    private var ownsLock = false

    init(path: URL = HousekeeperLock.defaultPathURL,
         staleMinutes: Double = HousekeeperLock.defaultStaleMinutes,
         fileManager: FileManager = .default) {
        self.path = path
        self.staleInterval = staleMinutes * 60
        self.fileManager = fileManager
    }

    /// True when this process is already the lock owner.
    ///
    /// The Python lock sets `HOUSEKEEPER_LOCK_OWNER=1` for its children so a
    /// parent does not deadlock its own subprocesses, and the Swift side has
    /// to honor the same token.
    ///
    /// `getenv` rather than `ProcessInfo.processInfo.environment`, because
    /// that property is a snapshot taken when the process started: a token
    /// set after launch would be invisible through it, and the answer has to
    /// be true now, not only true at launch.
    static var isReentrantOwner: Bool {
        guard let value = getenv("HOUSEKEEPER_LOCK_OWNER") else { return false }
        return String(cString: value) == "1"
    }

    /// Take the lock, or report that a peer holds it.
    ///
    /// A lock that exists but is older than the stale window belongs to a
    /// process that died, so it is taken over.  A lock that exists and is
    /// fresh belongs to a peer, and the caller has to wait its turn.
    @discardableResult
    func acquire() -> Outcome {
        if HousekeeperLock.isReentrantOwner {
            // Already the owner: the token says so, so do not touch the
            // directory and do not take responsibility for removing it.
            return .acquired
        }

        do {
            try createLockDirectory()
            ownsLock = true
            return .acquired
        } catch {
            // The directory exists.  Either a peer holds it, or a killed
            // process left it behind.
            guard isStale else { return .heldByPeer }
            guard takeOverStaleLock() else { return .heldByPeer }
            do {
                try createLockDirectory()
                ownsLock = true
                return .acquired
            } catch {
                return .heldByPeer
            }
        }
    }

    /// Give the lock back.
    ///
    /// Only a lock this process took is removed.  A peer's lock is left
    /// exactly as it was found.
    func release() {
        guard ownsLock else { return }
        ownsLock = false
        removeIfEmpty()
    }

    deinit {
        release()
    }

    // MARK: - Internals

    private func createLockDirectory() throws {
        // The parent has to exist first: `withIntermediateDirectories: false`
        // is what makes this a lock, because it fails when the directory is
        // already there instead of succeeding like `true` would.
        try fileManager.createDirectory(at: path.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try fileManager.createDirectory(at: path, withIntermediateDirectories: false)
    }

    /// True when the lock is older than the stale window.
    ///
    /// A lock whose modification date cannot be read is treated as stale: it
    /// is more likely to be a leftover than a live peer, and the Python lock
    /// treats an unreadable lock the same way.
    private var isStale: Bool {
        isStale(at: path)
    }

    private func isStale(at url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else {
            return true
        }
        return Date().timeIntervalSince(modified) > staleInterval
    }

    /// Clear a stale lock so the caller can create a fresh one.
    ///
    /// Checking that the lock is stale and then removing it is two steps, and
    /// two reclaimers can interleave them: both see the stale lock, one
    /// removes it and creates a fresh one, and the other then removes that
    /// fresh, empty lock and creates its own, so both believe they hold it.
    /// Removing is therefore a rename, which only one caller can win: the
    /// stale directory is moved aside under a name no one else uses, and a
    /// caller that finds nothing to move lost the race and backs off.
    ///
    /// The rename acts on whatever is at the path at that instant.  When a
    /// peer had already replaced the stale lock, that is the peer's fresh
    /// lock, and it is put back rather than removed.
    private func takeOverStaleLock() -> Bool {
        let aside = path.deletingLastPathComponent()
            .appendingPathComponent(".housekeeper.lock.stale-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.moveItem(at: path, to: aside)
        } catch {
            return false
        }
        guard isStale(at: aside) else {
            // Someone else's fresh lock.  Put it back.
            putBack(aside)
            return false
        }
        // Only the stale directory is gone, and only when it is empty, as the
        // Python side's `rmdir` would.
        if let contents = try? fileManager.contentsOfDirectory(atPath: aside.path), contents.isEmpty {
            try? fileManager.removeItem(at: aside)
        } else {
            putBack(aside)
            return false
        }
        return true
    }

    /// Return a directory that was moved aside to the lock path.
    ///
    /// `moveItem` fails when the path is already taken, and that is the case
    /// to leave alone: a third caller created a lock in the instant the path
    /// was empty, and putting this one back would mean replacing theirs.  So
    /// a failed put-back changes nothing.  The moved directory stays beside the
    /// lock under its `.stale-` name and is never deleted, because it may be
    /// a live peer's lock.  That peer is displaced, which is the window a
    /// rename cannot close and only a lock primitive shared with the Python
    /// and shell sides could.
    private func putBack(_ aside: URL) {
        do {
            try fileManager.moveItem(at: aside, to: path)
        } catch {
            // Deliberately nothing: see above.
        }
    }

    /// Remove the lock directory, but only when it is empty.
    ///
    /// The Python side uses `rmdir`, which also refuses a non-empty
    /// directory.  Matching that matters: the lock is a marker, and a
    /// directory with contents in it is not the marker we made.
    private func removeIfEmpty() {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: path.path),
              contents.isEmpty else { return }
        try? fileManager.removeItem(at: path)
    }
}
