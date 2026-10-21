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

    /// True when a marker sits anywhere under this path.
    ///
    /// The walk is bounded on both depth and entry count, because this runs
    /// on every candidate the cleaner considers.  A tree too big to answer
    /// within the bound answers "no marker found in what was read" rather
    /// than blocking the whole tree forever: an unreadable part of the tree
    /// is unreadable to the delete as well, so a marker inside one of those
    /// parts survives the delete instead of being taken with it.
    static func containsMarker(url: URL,
                               maxDepth: Int = 6,
                               fileCap: Int = 2_000,
                               fileManager: FileManager = .default) -> Bool {
        var visited = 0
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return false
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
        return false
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
