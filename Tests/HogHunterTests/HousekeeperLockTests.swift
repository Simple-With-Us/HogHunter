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

    func testATakeOverLeavesNothingBehindBesideTheLock() throws {
        // The stale lock is moved aside to be replaced, and the moved copy is
        // removed.  A leftover would pile up one directory per crash.
        let dead = HousekeeperLock(path: lockPath)
        _ = dead.acquire()
        let old = Date().addingTimeInterval(-(HousekeeperLock.defaultStaleMinutes + 5) * 60)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: lockPath.path)

        let fresh = HousekeeperLock(path: lockPath)
        XCTAssertEqual(fresh.acquire(), .acquired)

        let siblings = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(siblings, [".housekeeper.lock"], "only the new lock is left")
        fresh.release()
    }

    func testAStaleLockWithSomethingInsideIsLeftWhereItWas() throws {
        // The Python side's `rmdir` refuses a directory with contents, so a
        // stale lock holding something is not the marker this code made and
        // is not taken over.  Moving it aside must not lose it.
        let dead = HousekeeperLock(path: lockPath)
        _ = dead.acquire()
        let inside = lockPath.appendingPathComponent("owner.txt")
        FileManager.default.createFile(atPath: inside.path, contents: Data("busy".utf8))
        let old = Date().addingTimeInterval(-(HousekeeperLock.defaultStaleMinutes + 5) * 60)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: lockPath.path)

        let other = HousekeeperLock(path: lockPath)
        XCTAssertEqual(other.acquire(), .heldByPeer)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inside.path), "the lock is back in place with its contents")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(siblings, [".housekeeper.lock"])
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
}
