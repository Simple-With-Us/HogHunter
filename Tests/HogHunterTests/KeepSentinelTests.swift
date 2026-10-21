import XCTest
@testable import HogHunter

/// Covers the `.janitor-keep` marker convention.
///
/// The marker is the operator's only way to say "not this one" to an
/// unattended run, so the probe has to answer exactly the way the Python
/// engine does: a marker on the path or on any parent protects it, a marker
/// anywhere under a tree is found, and both probes are case-insensitive.
///
/// The Python original is in `scripts/hoghunter-clean` (`has_keep_sentinel`
/// and `holds_keep_sentinel`).  A disagreement between the two is not a
/// cosmetic bug -- the one that disagrees the other way is the one that
/// deletes what the operator marked.
final class KeepSentinelTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HogHunterKeepTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        super.tearDown()
    }

    private func makeDirectory(_ relativePath: String) -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeMarker(in directory: URL, named name: String = KeepSentinel.fileName) {
        FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: Data())
    }

    // MARK: - isKept

    func testAMarkerOnThePathItselfProtectsIt() {
        let dir = makeDirectory("marked")
        makeMarker(in: dir)
        XCTAssertTrue(KeepSentinel.isKept(url: dir))
    }

    func testAMarkerOnAParentProtectsTheChild() {
        let parent = makeDirectory("parent")
        let child = makeDirectory("parent/child")
        makeMarker(in: parent)
        XCTAssertTrue(KeepSentinel.isKept(url: child))
    }

    func testAnUnmarkedPathIsNotKept() {
        let dir = makeDirectory("unmarked")
        XCTAssertFalse(KeepSentinel.isKept(url: dir))
    }

    func testAMarkerIsFoundWhateverItsCase() {
        // The Python probe resolves the marker with Path.exists(), which is
        // case-insensitive on the default case-insensitive APFS volume.  A
        // case-sensitive probe here would make the Swift cleaner and the
        // Python engine disagree about the same marker.
        let dir = makeDirectory("upper")
        makeMarker(in: dir, named: ".JANITOR-KEEP")
        XCTAssertTrue(KeepSentinel.isKept(url: dir))
    }

    // MARK: - containsMarker

    func testAMarkerUnderTheTreeIsFound() {
        let tree = makeDirectory("tree")
        let nested = tree.appendingPathComponent("a/b/c", isDirectory: true)
        try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        makeMarker(in: nested)

        XCTAssertTrue(KeepSentinel.containsMarker(url: tree))
    }

    func testATreeWithNoMarkerIsNotFlagged() {
        let tree = makeDirectory("clean")
        let nested = tree.appendingPathComponent("a/b", isDirectory: true)
        try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertFalse(KeepSentinel.containsMarker(url: tree))
    }

    func testTheWalkIsCaseInsensitiveToo() {
        // The Python probe that looks inside a tree uses `find -iname`.
        let tree = makeDirectory("tree2")
        let nested = tree.appendingPathComponent("x", isDirectory: true)
        try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        makeMarker(in: nested, named: ".Janitor-Keep")

        XCTAssertTrue(KeepSentinel.containsMarker(url: tree))
    }

    func testTheWalkRespectsItsDepthBound() {
        // A marker deeper than the bound is not reported.  The answer stays
        // "not seen", which is the safe direction: an unreadable part of a
        // tree is unreadable to the delete as well, so the marker survives
        // it instead of being taken with it.
        let tree = makeDirectory("deep")
        let deep = tree.appendingPathComponent("1/2/3/4/5/6/7/8", isDirectory: true)
        try? FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        makeMarker(in: deep)

        XCTAssertFalse(KeepSentinel.containsMarker(url: tree, maxDepth: 3))
        XCTAssertTrue(KeepSentinel.containsMarker(url: tree, maxDepth: 12))
    }

    func testTheWalkRespectsItsFileCap() {
        let tree = makeDirectory("many")
        for index in 0..<20 {
            let file = tree.appendingPathComponent("file-\(index).txt")
            FileManager.default.createFile(atPath: file.path, contents: Data())
        }
        let marked = tree.appendingPathComponent("zz-last", isDirectory: true)
        try? FileManager.default.createDirectory(at: marked, withIntermediateDirectories: true)
        makeMarker(in: marked)

        // The cap is reached before the walk can reach the marker.
        XCTAssertFalse(KeepSentinel.containsMarker(url: tree, fileCap: 1))
        // With room to finish, the marker is found.
        XCTAssertTrue(KeepSentinel.containsMarker(url: tree, fileCap: 100))
    }
}
