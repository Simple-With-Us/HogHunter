import Foundation
#if canImport(Darwin)
import Darwin
#endif

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
///
/// The owner file
/// --------------
/// The lock directory on disk does not say who is holding it.  When a tick is
/// killed hard -- `os._exit` skips `finally` and `atexit` -- the directory
/// survived and every tick after it reported "peer holds lock" until the two
/// hour stale window expired.  That is why the vacuum had not completed a
/// tick in six days.
///
/// Both sides now write an *owner file* beside the lock directory, naming the
/// pid that holds it.  A holder whose pid is gone is taken over at once
/// instead of after the stale window.  The owner file is a sibling and not a
/// file inside the lock directory, because `mac-auto-cleanup.sh` releases the
/// lock with a plain `rmdir`, and `rmdir` refuses a directory with anything
/// in it.
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

    /// The identity file that sits beside the lock directory.
    ///
    /// It has to be a sibling, not a file inside the lock directory, because
    /// `mac-auto-cleanup.sh` releases the lock with a plain `rmdir` and
    /// `rmdir` refuses a directory that has anything in it.
    var ownerPath: URL {
        path.deletingLastPathComponent()
            .appendingPathComponent(path.lastPathComponent + ".owner")
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
    /// fresh belongs to a peer, and the caller has to wait its turn -- unless
    /// the peer is demonstrably gone, in which case it is taken over at once
    /// rather than after the stale window.
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
            writeOwnerFile()
            return .acquired
        } catch {
            // The directory exists.  Either a peer holds it, or a killed
            // process left it behind.
            guard isStale || isOwnerGone else { return .heldByPeer }
            guard takeOverStaleLock() else { return .heldByPeer }
            do {
                try createLockDirectory()
                ownsLock = true
                writeOwnerFile()
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
        removeOwnerFile()
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
        // The owner file is read before the move, because the move is what
        // decides the race and the file is only removed when it still names
        // the dead holder we found.
        let deadOwnerPid = ownerPid()
        let aside = path.deletingLastPathComponent()
            .appendingPathComponent(".housekeeper.lock.stale-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.moveItem(at: path, to: aside)
        } catch {
            return false
        }
        guard currentOwnerPid() == deadOwnerPid else {
            // The owner file names somebody else now.  A new holder took over
            // between our read and our move, so what we moved aside is that
            // holder's lock.  Put it back.
            putBack(aside)
            return false
        }
        // The moved lock is free to take when it is old enough, or when the
        // holder we found is gone.  The second case is not a rare one: a tick
        // killed a minute ago leaves a *fresh* directory behind, and the age
        // rule alone would refuse it, which is the wedge this whole change
        // exists to undo.
        let movedIsStale = isStale(at: aside)
        let ownerIsGone = deadOwnerPid.map { $0 > 0 && !HousekeeperLock.isProcessAlive($0) } ?? false
        guard movedIsStale || ownerIsGone else {
            // Someone else's fresh lock, held by a live process.  Put it back.
            putBack(aside)
            return false
        }
        // Only the stale directory is gone, and only when it is empty, as the
        // Python side's `rmdir` would.
        if let contents = try? fileManager.contentsOfDirectory(atPath: aside.path), contents.isEmpty {
            // The owner file belongs to the holder we just moved aside.  It is
            // removed only when it still names that same pid, so a new
            // holder's own file is never taken away.
            if let deadOwnerPid, currentOwnerPid() == deadOwnerPid {
                removeOwnerFile()
            }
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

    /// True when the recorded owner is definitely gone.
    ///
    /// A missing or unreadable owner file is *not* proof of anything: the
    /// shell holder never wrote one, so the caller falls back to the age
    /// rule.  Guessing wrong in that direction would steal a live lock.
    private var isOwnerGone: Bool {
        guard ownerDescribesHolder(), let pid = ownerPid(), pid > 0, pid != getpid() else {
            return false
        }
        return !HousekeeperLock.isProcessAlive(pid)
    }

    /// True when the owner file describes the holder of the lock that is
    /// there now.
    ///
    /// A holder that never wrote an owner file -- the shell holder -- leaves
    /// a leftover file from an earlier holder beside it.  That file names a
    /// pid that is gone, and reading it as the current holder would let a
    /// fresh live lock be taken over.  The owner file is only about the
    /// current holder when it is at least as new as the lock directory.
    private func ownerDescribesHolder() -> Bool {
        guard let ownerAttributes = try? fileManager.attributesOfItem(atPath: ownerPath.path),
              let ownerModified = ownerAttributes[.modificationDate] as? Date,
              let lockAttributes = try? fileManager.attributesOfItem(atPath: path.path),
              let lockModified = lockAttributes[.modificationDate] as? Date else {
            return false
        }
        return ownerModified >= lockModified
    }

    /// The pid recorded in the owner file, when there is a readable one.
    private func ownerPid() -> Int32? {
        guard let data = fileManager.contents(atPath: ownerPath.path),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let pid = dict["pid"] as? NSNumber else {
            return nil
        }
        return pid.int32Value
    }

    /// The pid the owner file names right now.
    private func currentOwnerPid() -> Int32? {
        ownerPid()
    }

    /// True when a pid still names a live process.
    ///
    /// Signal 0 delivers nothing; it only asks the kernel whether the process
    /// exists.  EPERM means it exists but belongs to somebody else, and that
    /// counts as alive.
    static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Record who holds the lock.
    ///
    /// The pid is what makes a killed holder recoverable.  A failure to write
    /// is not fatal: the lock directory is the real mutex, and the owner file
    /// only makes recovery fast.
    private func writeOwnerFile() {
        var payload: [String: Any] = [
            "pid": Int(getpid()),
            "acquired_at": Date().timeIntervalSince1970,
            "lock": path.path,
        ]
        let host = ProcessInfo.processInfo.hostName
        if !host.isEmpty { payload["host"] = host }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: ownerPath, options: .atomic)
    }

    /// Remove the owner file.
    private func removeOwnerFile() {
        guard fileManager.fileExists(atPath: ownerPath.path) else { return }
        try? fileManager.removeItem(at: ownerPath)
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
