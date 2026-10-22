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
///
/// The mutation guard
/// ------------------
/// The owner file makes a *dead* holder recoverable.  The guard is what makes
/// a *racing* holder impossible.  The same housekeeper protocol is written in
/// four places -- this file, `scripts/vacuum/lock.py`, and AFC's
/// `mac-auto-cleanup.sh` and `mac-resource-watch.py` -- so all four hold the
/// SAME guard: a plain file beside the lock directory, named
/// `.housekeeper.lock.guard`, taken with an exclusive `flock`.
///
/// The guard is held across the whole critical section: the ownership check,
/// the stale takeover, the removal, the `mkdir`, the owner-file publication,
/// and every release path.  Two reclaimers that both decide to take a stale
/// lock over cannot interleave inside it, and a release cannot slip between
/// its own ownership check and its removal.
///
/// The guard file is NEVER deleted.  Deleting it would split the flock: two
/// processes could each hold a different inode and both believe they hold the
/// guard.
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

    /// The device and inode of a directory.
    ///
    /// Two paths with the same identity are the same directory, so the
    /// identity tells the lock this process took from a lock a new holder
    /// has put in its place.
    struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private let path: URL
    private let staleInterval: TimeInterval
    private let fileManager: FileManager
    private var ownsLock = false
    /// The identity of the lock directory this process created.
    private var lockIdentityAtAcquire: FileIdentity?

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
    /// `rmdir` refuses a directory with anything in it.
    var ownerPath: URL {
        path.deletingLastPathComponent()
            .appendingPathComponent(path.lastPathComponent + ".owner")
    }

    /// The mutation guard that sits beside the lock directory.
    ///
    /// It is a sibling for the same reason the owner file is one, and it is
    /// the same file the Python lock and AFC's scripts take.
    var guardPath: URL {
        path.deletingLastPathComponent()
            .appendingPathComponent(path.lastPathComponent + ".guard")
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

        // The guard is held across the whole critical section: the
        // ownership check, the stale takeover, the removal, the `mkdir` and
        // the owner-file publication.  Two reclaimers that both decide to
        // take the same stale lock over cannot interleave inside it.
        let guardHandle = HousekeeperLock.acquireGuard(at: guardPath)
        defer { HousekeeperLock.releaseGuard(guardHandle) }

        do {
            try createLockDirectory()
            ownsLock = true
            lockIdentityAtAcquire = identity(at: path)
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
                lockIdentityAtAcquire = identity(at: path)
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
        // The guard is held across the ownership check and the removal, so
        // a takeover cannot slip between them and lose its lock.
        let guardHandle = HousekeeperLock.acquireGuard(at: guardPath)
        defer { HousekeeperLock.releaseGuard(guardHandle) }
        // The lock DIRECTORY goes first and the owner file second.  The
        // other order strands the lock: if the directory removal fails
        // after the owner file is gone, the lock is there with nobody
        // owning it, and nothing can take it over until the whole stale
        // window has passed.
        if removeLockDirectory() {
            removeOwnerFile()
        }
    }

    deinit {
        release()
    }

    // MARK: - The mutation guard

    /// One process's handle on the mutation guard of one lock.
    private final class GuardHandle {
        let key: String
        let fd: Int32
        /// The process that opened the descriptor.
        ///
        /// A forked child inherits the table, and the descriptors in it
        /// belong to the parent.  The child has to open its own, or it
        /// would take the parent's guard without ever asking for it.
        let pid: pid_t
        var depth: Int

        init(key: String, fd: Int32, pid: pid_t) {
            self.key = key
            self.fd = fd
            self.pid = pid
            self.depth = 0
        }
    }

    /// The guards this process holds, by path.
    ///
    /// The handle is kept rather than reopened, because `flock` belongs to
    /// the open file description: a second descriptor on the same file is a
    /// second lock, and taking it while this process already holds the first
    /// would deadlock the process against itself.
    private static var guardHandles: [String: GuardHandle] = [:]
    private static let guardTable = NSLock()

    /// Take the mutation guard for a lock.
    ///
    /// The guard is re-entrant inside one process: taking it again while
    /// this process already holds it does not block, and it is let go only
    /// when the last holder releases it.  Nothing that needs the guard is
    /// ever waited for while the guard is held, so it cannot deadlock.
    private static func acquireGuard(at guardPath: URL) -> GuardHandle? {
        #if canImport(Darwin)
        let key = guardPath.path
        guardTable.lock()
        defer { guardTable.unlock() }
        if let existing = guardHandles[key], existing.pid == getpid() {
            existing.depth += 1
            return existing
        }
        try? FileManager.default.createDirectory(at: guardPath.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // The guard file is never deleted.  Deleting it would split the
        // flock, and two processes could each hold a different inode and
        // both believe they hold the guard.
        let fd = open(guardPath.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX) == 0 else {
            close(fd)
            return nil
        }
        let handle = GuardHandle(key: key, fd: fd, pid: getpid())
        handle.depth = 1
        guardHandles[key] = handle
        return handle
        #else
        return nil
        #endif
    }

    /// Let the guard go, and close the descriptor when nobody holds it.
    private static func releaseGuard(_ handle: GuardHandle?) {
        #if canImport(Darwin)
        guard let handle else { return }
        guard handle.pid == getpid() else { return }
        guardTable.lock()
        defer { guardTable.unlock() }
        handle.depth -= 1
        guard handle.depth <= 0 else { return }
        handle.depth = 0
        _ = flock(handle.fd, LOCK_UN)
        guardHandles.removeValue(forKey: handle.key)
        close(handle.fd)
        #endif
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

    /// The device and inode of a path, when it can be read.
    private func identity(at url: URL) -> FileIdentity? {
        #if canImport(Darwin)
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
        #else
        return nil
        #endif
    }

    /// True when the directory at a path is the lock this process took.
    private func isOurLock(at url: URL) -> Bool {
        guard let ours = lockIdentityAtAcquire else { return true }
        guard let theirs = identity(at: url) else { return false }
        return theirs == ours
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
        // The moved-aside name is derived from the lock path, so it works
        // for any lock path and not only for the production one.
        let aside = path.deletingLastPathComponent()
            .appendingPathComponent("\(path.lastPathComponent).stale-\(UUID().uuidString)",
                                     isDirectory: true)
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
            try? fileManager.removeItem(at: aside)
            // The owner file belongs to the holder we just moved aside.  It is
            // removed only when it still names that same pid, so a new
            // holder's own file is never taken away.  It goes after the
            // directory, because a lock with no owner file is a lock that
            // nothing can take over until the whole stale window has passed.
            if let deadOwnerPid {
                removeOwnerFile(naming: deadOwnerPid)
            }
        } else {
            putBack(aside)
            return false
        }
        return true
    }

    /// Remove the lock directory, but only when it is still the one this
    /// process took.
    ///
    /// The directory is moved aside first, because a check and a removal are
    /// two steps and a takeover can slip between them: the check says "this
    /// is the lock I took", a new holder replaces the path with its own
    /// lock, and the removal then takes the NEW holder's lock away while
    /// that holder goes on believing it holds the lock.  Moving the
    /// directory aside is one decision, and what lands there is whatever
    /// was at the path, so it goes back untouched when it turns out not to
    /// be ours.
    ///
    /// The Python side uses `rmdir`, which also refuses a non-empty
    /// directory.  Matching that matters: the lock is a marker, and a
    /// directory with contents in it is not the marker we made.
    private func removeLockDirectory() -> Bool {
        let aside = path.deletingLastPathComponent()
            .appendingPathComponent("\(path.lastPathComponent).release-\(UUID().uuidString)",
                                     isDirectory: true)
        guard HousekeeperLock.moveExclusive(path, aside) else { return false }
        let contents = (try? fileManager.contentsOfDirectory(atPath: aside.path)) ?? []
        guard contents.isEmpty, isOurLock(at: aside) else {
            // Not ours, or not the empty marker we made: put it back exactly
            // as it was.
            HousekeeperLock.moveExclusive(aside, path)
            return false
        }
        try? fileManager.removeItem(at: aside)
        return true
    }

    /// Return a directory that was moved aside to the lock path.
    ///
    /// The move refuses when the path is already taken, and that is the case
    /// to leave alone: a third caller created a lock in the instant the path
    /// was empty, and putting this one back would mean replacing theirs.  So
    /// a failed put-back changes nothing.  The moved directory stays beside
    /// the lock under its `.stale-` name and is never deleted, because it
    /// may be a live peer's lock.
    ///
    /// The refusal has to be atomic.  `FileManager.moveItem` checks that the
    /// destination is free and then renames, so a peer that takes the path in
    /// between is replaced instead of refused, and the replacement is silent:
    /// the peer goes on believing it holds the lock while this one sweeps at
    /// the same time.  macOS's `renameatx_np` with `RENAME_EXCL` makes the
    /// move and the refusal one decision, so there is no window for a peer to
    /// slip into.
    private func putBack(_ aside: URL) {
        #if canImport(Darwin)
        _ = HousekeeperLock.moveExclusive(aside, path)
        #else
        do {
            try fileManager.moveItem(at: aside, to: path)
        } catch {
            // Deliberately nothing: see above.
        }
        #endif
    }

    /// Move a directory onto a path that must be free, atomically.
    ///
    /// Returns false when the destination is already taken, and nothing is
    /// changed: the source stays where it is and the destination is left
    /// exactly as it was.  The check and the move are one decision, so a peer
    /// that takes the destination a moment later is refused rather than
    /// replaced.
    static func moveExclusive(_ source: URL, _ destination: URL) -> Bool {
        #if canImport(Darwin)
        let renameExcl: UInt32 = 0x00000004
        return source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                renameatx_np(AT_FDCWD, sourcePath, AT_FDCWD, destinationPath, renameExcl) == 0
            }
        }
        #else
        if FileManager.default.fileExists(atPath: destination.path) {
            return false
        }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            return true
        } catch {
            return false
        }
        #endif
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

    /// Remove the owner file, but only when it is this process's own.
    ///
    /// A lock that was taken over while this one was still running names the
    /// new holder now, and deleting that file takes away the new holder's
    /// identity.  A file that names no readable pid belongs to nobody, so it
    /// goes.
    private func removeOwnerFile() {
        guard let pid = ownerPid() else {
            try? fileManager.removeItem(at: ownerPath)
            return
        }
        guard pid == getpid() else { return }
        try? fileManager.removeItem(at: ownerPath)
    }

    /// Remove the owner file, but only when it names a given pid.
    ///
    /// This is the takeover's rule: the file belongs to the holder that was
    /// moved aside, and it goes only while it still names that holder.
    private func removeOwnerFile(naming pid: Int32) {
        guard currentOwnerPid() == pid else { return }
        try? fileManager.removeItem(at: ownerPath)
    }
}
