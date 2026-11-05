import Foundation

/// The `.janitor-keep` marker convention, mirrored from the Python engine.
///
/// The original lives in `scripts/hoghunter-clean`, and it answers two
/// different questions:
///
/// - `has_keep_sentinel(path)` — a marker sits on this path or on any parent
///   of it.  A marker on a parent protects the child, so a whole tree of
///   marked paths is left alone.
/// - `holds_keep_sentinel(path)` — a marker sits anywhere *under* this path.
///   The rules that delete whole trees have to ask this, because deleting
///   the tree would take the operator's marker with it.
///
/// The Swift cleaner deletes the same kinds of things the Python engine
/// does, so it has to honor the same markers.  An unattended regimen is the
/// sharpest version of this problem: there is nobody standing there to say
/// "not that one", so the marker is the only thing keeping it.
///
/// Case sensitivity matters.  The Python probe that looks inside a tree uses
/// `find -iname`, which is case-insensitive, and the one that looks at a
/// path resolves the marker with `Path.exists()`, which is case-insensitive
/// on the default case-insensitive APFS volume.  With a case-sensitive probe
/// a marker spelled `.JANITOR-KEEP` would be honored at a tree root and
/// invisible inside one, and the engine would delete the tree and the marker
/// together.  Both probes here recognize exactly the same markers.
enum KeepSentinel {
    /// The marker file name.
    static let fileName = ".janitor-keep"

    /// True when a marker sits on this path or on any parent of it.
    static func isKept(url: URL, fileManager: FileManager = .default) -> Bool {
        var current = url.standardizedFileURL
        while true {
            if hasMarker(in: current, fileManager: fileManager) { return true }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { return false }
            current = parent
        }
    }

    /// True when a marker sits anywhere under this path, within the walk's bound.
    ///
    /// The walk is bounded on both depth and entry count, because this runs
    /// on every candidate the cleaner considers.  A tree too big to answer
    /// within the bound answers "no marker found in what was read" rather
    /// than blocking the whole tree forever, because a tree of more than
    /// 2,000 entries is the normal state of an Xcode or package cache.  That
    /// makes this a best-effort check and not a guarantee: a marker deeper or
    /// further in than the bound is not seen, and `clean()` trashes the whole
    /// tree, including the parts the walk did not read.  HH-184 replaces the
    /// bound with a complete walk under a time budget that fails closed on
    /// timeout, as the Python engine does.
    static func containsMarker(url: URL,
                               maxDepth: Int = 6,
                               fileCap: Int = 2_000,
                               fileManager: FileManager = .default) -> Bool {
        // An unreadable subtree answers "kept".  The walk skips what it
        // cannot read, and a marker inside the skipped part would otherwise
        // be missed and the tree trashed with it.  Skipping the clean of one
        // tree is the safe side; the cap and depth bounds below stay
        // best-effort (HH-184), because trees over 2,000 entries are the
        // cleaner's normal workload, not an error.
        var sawError = false
        var visited = 0
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in
                sawError = true
                return true
            }
        ) else {
            return true
        }
        while let element = enumerator.nextObject() as? URL {
            visited += 1
            if visited > fileCap { return false }
            if element.lastPathComponent.caseInsensitiveCompare(fileName) == .orderedSame {
                return true
            }
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
            }
        }
        return sawError
    }

    /// True when a marker sits anywhere under this path, or when nobody can say.
    ///
    /// The whole tree, with no bound on entries or depth, because the one bound
    /// here fails closed: a walk that runs out of time, or cannot read part of the
    /// tree, answers "kept".  `containsMarker` stays bounded for the trees where
    /// that would hide every row.  Use this for a tree whose normal state is far
    /// past that bound and that holds someone's marked work, one tree at a time.
    static func containsMarkerInWholeTree(url: URL,
                                          timeBudget: TimeInterval = 30,
                                          fileManager: FileManager = .default,
                                          now: () -> Date = Date.init) -> Bool {
        var sawError = false
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in
                sawError = true
                return true
            }
        ) else {
            return true
        }
        let deadline = now().addingTimeInterval(timeBudget)
        var visited = 0
        while let element = enumerator.nextObject() as? URL {
            if element.lastPathComponent.caseInsensitiveCompare(fileName) == .orderedSame {
                return true
            }
            visited += 1
            if visited % 256 == 1, now() > deadline {
                return true
            }
        }
        return sawError
    }

    /// True when the directory holds a marker.
    ///
    /// `fileExists` rather than a directory listing, because that is exactly
    /// what the Python probe does: `has_keep_sentinel` resolves the marker
    /// with `Path.exists()`, which is case-insensitive on the default
    /// case-insensitive APFS volume.  Using a case-sensitive probe here would
    /// make the Swift cleaner and the Python engine disagree about the same
    /// marker, and the one that disagrees the other way is the one that
    /// deletes what the operator marked.
    private static func hasMarker(in directory: URL, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: directory.appendingPathComponent(fileName).path)
    }
}
