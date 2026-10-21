import XCTest
@testable import HogHunter

/// Covers the Swift side of the housekeeper lock.
///
/// The lock is mutual exclusion between the in-app regimen and the Python
/// reclaim ticks, so the properties that matter are these: a second holder is
/// refused, a stale lock left by a dead process is taken over, a lock this
/// process did not take is never removed, and the re-entrancy token means the
/// owner's own children do not deadlock it.
///
/// The Python original is `scripts/vacuum/lock.py`, and the two have to agree
/// on the path, the staleness window, the token and the "only remove a lock
/// you took" rule -- a disagreement here means two reclaimers racing over one
/// file.
final class HousekeeperLockTests: XCTestCase {

    private var root: URL!
    private var lockPath: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HogHunterLockTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        lockPath = root.appendingPathComponent(".housekeeper.lock", isDirectory: true)
    }

    override func tearDown() {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        super.tearDown()
    }

    // MARK: - Acquire and release

    func testAcquireCreatesTheLockAsADirectory() {
        let lock = HousekeeperLock(path: lockPath)
        XCTAssertEqual(lock.acquire(), .acquired)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "the lock is a directory, because mkdir is what makes it atomic")

        lock.release()
    }

    func testAPeerHoldingTheLockIsRefused() {
        let first = HousekeeperLock(path: lockPath)
        XCTAssertEqual(first.acquire(), .acquired)

        let second = HousekeeperLock(path: lockPath)
        XCTAssertEqual(second.acquire(), .heldByPeer)

        // The peer's lock is still there, untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath.path))
        first.release()
    }

    func testReleaseRemovesTheLock() {
        let lock = HousekeeperLock(path: lockPath)
        _ = lock.acquire()
        lock.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath.path))
    }

    func testReleaseOnALockThisProcessDidNotTakeLeavesThePeersLockAlone() {
        let peer = HousekeeperLock(path: lockPath)
        XCTAssertEqual(peer.acquire(), .acquired)

        let other = HousekeeperLock(path: lockPath)
        XCTAssertEqual(other.acquire(), .heldByPeer)
        other.release()  // never took it, so it must not remove the peer's lock

        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath.path))
        peer.release()
    }

    func testALockWithContentsIsNotRemoved() {
        // The Python side uses rmdir, which also refuses a non-empty
        // directory.  The lock is a marker, and a directory with something in
        // it is not the marker we made.
        let lock = HousekeeperLock(path: lockPath)
        _ = lock.acquire()
        let inside = lockPath.appendingPathComponent("owner.txt")
        FileManager.default.createFile(atPath: inside.path, contents: Data("busy".utf8))

        lock.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inside.path))
    }

    // MARK: - Stale locks

    func testAStaleLockIsTakenOver() {
        let dead = HousekeeperLock(path: lockPath)
        _ = dead.acquire()
        // Backdate it past the stale window: a process that died mid-run and
        // left its lock behind.
        let old = Date().addingTimeInterval(-(HousekeeperLock.defaultStaleMinutes + 5) * 60)
        try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: lockPath.path)

        let fresh = HousekeeperLock(path: lockPath)
        XCTAssertEqual(fresh.acquire(), .acquired)
        fresh.release()
    }

    func testAFreshLockIsNotTakenOver() {
        let live = HousekeeperLock(path: lockPath)
        _ = live.acquire()

        let other = HousekeeperLock(path: lockPath)
        XCTAssertEqual(other.acquire(), .heldByPeer)
        live.release()
    }

    // MARK: - Re-entrancy

    func testTheOwnerTokenLetsAChildThroughWithoutTouchingTheDirectory() {
        // The peer takes the lock normally, with no token: it is a real
        // holder, and the directory has to be there for the rest to mean
        // anything.
        let peer = HousekeeperLock(path: lockPath)
        XCTAssertEqual(peer.acquire(), .acquired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath.path))

        // The Python lock sets HOUSEKEEPER_LOCK_OWNER=1 for its children, so a
        // parent does not deadlock its own subprocesses.  The Swift side has to
        // honor the same token.
        setenv("HOUSEKEEPER_LOCK_OWNER", "1", 1)
        defer { unsetenv("HOUSEKEEPER_LOCK_OWNER") }

        XCTAssertTrue(HousekeeperLock.isReentrantOwner)

        // Even a lock that exists and is fresh is let through with the token.
        let child = HousekeeperLock(path: lockPath)
        XCTAssertEqual(child.acquire(), .acquired)

        // The child never took the lock, so it must not remove it.
        child.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath.path))

        // The real holder still owns it, and releasing it takes it away.
        peer.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath.path))
    }

    func testWithoutTheTokenAFreshLockIsStillRefused() {
        unsetenv("HOUSEKEEPER_LOCK_OWNER")
        XCTAssertFalse(HousekeeperLock.isReentrantOwner)

        let peer = HousekeeperLock(path: lockPath)
        _ = peer.acquire()
        let other = HousekeeperLock(path: lockPath)
        XCTAssertEqual(other.acquire(), .heldByPeer)
        peer.release()
    }

    // MARK: - The owner file

    /// The owner file is what makes a killed holder recoverable at once.
    ///
    /// The watchdog in `scripts/maintain.py` exits with `os._exit`, which skips
    /// the lock's `__exit__`, so the lock directory used to survive a killed
    /// tick and every tick after it reported "peer holds lock" until the two
    /// hour stale window expired.  The owner file names the holding pid, so a
    /// holder that is demonstrably gone is taken over immediately.

    private func writeOwner(pid: Int32) {
        let payload: [String: Any] = ["pid": Int(pid), "acquired_at": Date().timeIntervalSince1970]
        let data = try? JSONSerialization.data(withJSONObject: payload)
        try? data?.write(to: ownerPath)
    }

    private var ownerPath: URL {
        lockPath.deletingLastPathComponent()
            .appendingPathComponent(lockPath.lastPathComponent + ".owner")
    }

    func testAcquireWritesAnOwnerFileBesideTheLock() {
        let lock = HousekeeperLock(path: lockPath)
        XCTAssertEqual(lock.acquire(), .acquired)

        XCTAssertTrue(FileManager.default.fileExists(atPath: ownerPath.path),
                      "the owner file records who holds the lock")
        let data = try? Data(contentsOf: ownerPath)
        let object = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
        XCTAssertEqual(object?["pid"] as? Int, Int(getpid()))

        lock.release()
    }

    func testTheOwnerFileIsARivalOfTheLockDirectoryNotInsideIt() {
        // `~/apps/mac-auto-cleanup.sh` releases the lock with a plain `rmdir`,
        // and `rmdir` refuses a directory that has anything in it.  An owner
        // file inside the lock would make the shell's release silently fail
        // and leak the lock forever.
        let lock = HousekeeperLock(path: lockPath)
        XCTAssertEqual(lock.acquire(), .acquired)

        let contents = try? FileManager.default.contentsOfDirectory(atPath: lockPath.path)
        XCTAssertEqual(contents?.isEmpty, true, "the lock directory must stay empty for the shell's rmdir")

        lock.release()
    }

    func testReleaseRemovesTheOwnerFile() {
        let lock = HousekeeperLock(path: lockPath)
        _ = lock.acquire()
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownerPath.path))
        lock.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownerPath.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath.path))
    }

    func testALockWhoseOwnerIsGoneIsTakenOverAtOnce() {
        // A pid above the system maximum cannot name a live process, so this
        // is what a lock left behind by a killed tick looks like.
        try? FileManager.default.createDirectory(at: lockPath, withIntermediateDirectories: true)
        writeOwner(pid: 999_999)

        let lock = HousekeeperLock(path: lockPath)
        XCTAssertEqual(lock.acquire(), .acquired,
                       "a lock whose owner is gone is taken over at once, not after the stale window")
        lock.release()
    }

    func testALockWhoseOwnerIsAliveIsRefused() {
        try? FileManager.default.createDirectory(at: lockPath, withIntermediateDirectories: true)
        writeOwner(pid: getpid())

        let lock = HousekeeperLock(path: lockPath)
        XCTAssertEqual(lock.acquire(), .heldByPeer,
                       "a live owner keeps the lock, however fresh the directory is")
    }

    func testAFreshLockWithNoOwnerFileIsNotTakenOver() {
        // The shell holder never writes an owner file, so a missing one is not
        // proof of anything.  The age rule decides.
        try? FileManager.default.createDirectory(at: lockPath, withIntermediateDirectories: true)

        let lock = HousekeeperLock(path: lockPath)
        XCTAssertEqual(lock.acquire(), .heldByPeer)
    }

    // MARK: - The atomic takeover

    /// Taking over a stale lock is a rename, not a remove and a create.
    ///
    /// Checking that a lock is stale and then removing it is two steps, and two
    /// reclaimers can interleave them: both see the stale lock, one removes it
    /// and creates a fresh one, and the other then removes that fresh, empty
    /// lock and creates its own, so both believe they hold it.  Moving the
    /// directory aside lets only one caller win the race.

    func testALeftoverOwnerFileOlderThanTheLockDoesNotUnlockIt() {
        // The shell holder never writes an owner file, so an owner file left
        // beside the lock can name a pid that is long gone.  Reading it as the
        // current holder would let a fresh, live lock be taken over.  The
        // owner file only describes the holder when it is at least as new as
        // the lock directory.
        try? FileManager.default.createDirectory(at: lockPath, withIntermediateDirectories: true)
        writeOwner(pid: 999_999)
        let older = Date().addingTimeInterval(-600)
        try? FileManager.default.setAttributes([.modificationDate: older], ofItemAtPath: ownerPath.path)

        let lock = HousekeeperLock(path: lockPath)
        XCTAssertEqual(lock.acquire(), .heldByPeer,
                       "a leftover owner file must not unlock a fresh lock")
    }

    func testAStaleLockIsMovedAsideAndLeavesNothingBehind() {
        try? FileManager.default.createDirectory(at: lockPath, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-(HousekeeperLock.defaultStaleMinutes + 5) * 60)
        try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: lockPath.path)

        let lock = HousekeeperLock(path: lockPath)
        XCTAssertEqual(lock.acquire(), .acquired)

        let leftovers = try? FileManager.default.contentsOfDirectory(atPath: root.path)
        let moved = (leftovers ?? []).filter { $0.contains(".stale-") }
        XCTAssertEqual(moved, [], "a taken-over stale lock leaves no moved-aside copy")
        lock.release()
    }

    func testALockWithContentsIsPutBackRatherThanRemoved() {
        // The lock is a marker: a directory with contents in it is not the
        // marker we made, so it is put back rather than removed.
        try? FileManager.default.createDirectory(at: lockPath, withIntermediateDirectories: true)
        let inside = lockPath.appendingPathComponent("leftover.txt")
        FileManager.default.createFile(atPath: inside.path, contents: Data("not ours".utf8))
        let old = Date().addingTimeInterval(-(HousekeeperLock.defaultStaleMinutes + 5) * 60)
        try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: lockPath.path)

        let lock = HousekeeperLock(path: lockPath)
        XCTAssertEqual(lock.acquire(), .heldByPeer)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath.path),
                      "the lock was put back")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inside.path),
                      "what was inside it is still there")
    }

    func testAFreshLockHeldByALiveProcessIsPutBackRatherThanRemoved() {
        // The move acts on whatever is at the path at that instant.  When a
        // peer had already replaced the stale lock, that is the peer's fresh
        // lock, and it is put back rather than removed.
        let peer = HousekeeperLock(path: lockPath)
        XCTAssertEqual(peer.acquire(), .acquired)

        // The peer's owner file names a live pid, so the lock is not free to
        // take and the peer keeps it.
        let other = HousekeeperLock(path: lockPath)
        XCTAssertEqual(other.acquire(), .heldByPeer)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath.path))
        peer.release()
    }
}
