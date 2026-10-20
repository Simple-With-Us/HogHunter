#if os(macOS)
import Foundation
import Darwin

/// A resumable physical-byte walk.  Only the executor's serial queue owns cursors/streams.
/// A slice limits metadata calls and elapsed time; no prefix is revisited between slices.
final class DirectorySizeWalker {
    struct Observation: Sendable {
        var path: String
        var bytes: Int64
        var entries: Int
        var startedAt: Date
        var finishedAt: Date?
        var failure: String?
        var isComplete: Bool { finishedAt != nil && failure == nil }
    }

    private struct Inode: Hashable {
        let device: dev_t
        let number: ino_t
    }
    private final class Frame {
        let path: String
        let stream: UnsafeMutablePointer<DIR>
        let device: dev_t
        let layoutDepth: Int?
        let inode: Inode
        init(path: String, stream: UnsafeMutablePointer<DIR>, device: dev_t, layoutDepth: Int?, inode: Inode) {
            self.path = path
            self.stream = stream
            self.device = device
            self.layoutDepth = layoutDepth
            self.inode = inode
        }
        deinit { closedir(stream) }
    }

    private(set) var observation: Observation
    private var frames: [Frame] = []
    private var hardLinks: [dev_t: Set<ino_t>] = [:]
    private var hardLinkCount = 0
    private var countedRoots: [String: dev_t] = [:]
    private var initialized = false
    private let includesLaneLinks: Bool

    init(path: String, startedAt: Date) {
        observation = Observation(path: path, bytes: 0, entries: 0, startedAt: startedAt)
        includesLaneLinks = URL(fileURLWithPath: path).lastPathComponent == "lanes"
    }

    func advance(maxEntries: Int = 256, maxDuration: TimeInterval = 0.04) -> Observation {
        guard observation.failure == nil, observation.finishedAt == nil else { return observation }
        let deadline = ProcessInfo.processInfo.systemUptime + maxDuration
        if !initialized {
            initialized = true
            // Resolution can touch a slow volume, so it belongs here, never in a view initializer.
            guard let physicalPath = Self.canonicalPath(observation.path) else {
                fail("Directory cannot be resolved (\(errno))")
                return observation
            }
            observation.path = physicalPath
            enter(observation.path, expectedDevice: nil, layoutDepth: includesLaneLinks ? 0 : nil, isRoot: true)
        }
        var processed = 0
        while observation.failure == nil, let frame = frames.last,
              processed < maxEntries, ProcessInfo.processInfo.systemUptime < deadline {
            errno = 0
            guard let entry = readdir(frame.stream) else {
                let error = errno
                frames.removeLast()
                if error != 0 { fail("Could not read every directory entry (\(error))") }
                continue
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingUTF8: $0) }
            }
            guard let name else { fail("Directory entry name cannot be decoded"); continue }
            guard name != ".", name != ".." else { continue }
            processed += 1
            let path = frame.path + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else {
                // A disappearing entry is a normal concurrent mutation, never a permission bypass.
                if errno != ENOENT { fail("Could not read metadata (\(errno))") }
                continue
            }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFDIR {
                enter(path, expectedDevice: frame.device, layoutDepth: frame.layoutDepth.map { $0 + 1 }, info: info)
            } else {
                add(info)
                if kind == S_IFLNK, let depth = frame.layoutDepth, depth < 2 {
                    guard let target = Self.canonicalPath(path) else {
                        if errno != ENOENT { fail("Linked directory cannot be resolved (\(errno))") }
                        continue
                    }
                    // Only explicit layout links may cross a volume.  Repository symlinks stay leaves.
                    if target != observation.path, !observation.path.hasPrefix(target + "/") {
                        var targetInfo = stat()
                        if lstat(target, &targetInfo) == 0 {
                            if targetInfo.st_mode & S_IFMT == S_IFDIR,
                               !Self.isCovered(path: target, device: targetInfo.st_dev, roots: countedRoots) {
                                // Keep earlier child partitions when a broader root appears later.
                                // Walking that parent skips those boundaries, counting only its extra data.
                                guard countedRoots.count < 4096 else { fail("Linked-root safety limit reached; last complete size retained"); continue }
                                enter(target, expectedDevice: nil, layoutDepth: nil, info: targetInfo, isRoot: true)
                            }
                        } else if errno != ENOENT {
                            fail("Linked directory is unavailable (\(errno))")
                        }
                    }
                }
            }
        }
        if observation.failure == nil, frames.isEmpty { observation.finishedAt = Date() }
        return observation
    }

    /// Foundation may shorten /private/tmp back to the /tmp symlink after resolution.
    /// Keep the POSIX physical path so the root passes lstat and O_NOFOLLOW checks.
    static func canonicalPath(_ path: String) -> String? {
        path.withCString { source in
            guard let resolved = Darwin.realpath(source, nil) else { return nil }
            defer { free(resolved) }
            guard let result = String(validatingUTF8: resolved) else { errno = EILSEQ; return nil }
            return result
        }
    }

    /// A same-device parent covers descendants; a nested mounted volume is excluded
    /// by normal traversal and must still be accepted through its explicit lane link.
    static func isCovered(path: String, device: dev_t, roots: [String: dev_t]) -> Bool {
        roots.contains { root, rootDevice in
            device == rootDevice && (path == root || path.hasPrefix(root + "/"))
        }
    }

    private func enter(_ path: String, expectedDevice: dev_t?, layoutDepth: Int?, info supplied: stat? = nil,
                       isRoot: Bool = false) {
        guard isRoot || countedRoots[path] == nil else { return }
        var info = supplied ?? stat()
        if supplied == nil, lstat(path, &info) != 0 { fail("Directory is unavailable (\(errno))"); return }
        guard info.st_mode & S_IFMT == S_IFDIR else { fail("Path is not a directory"); return }
        guard expectedDevice == nil || expectedDevice == info.st_dev else { return }
        if isRoot { countedRoots[path] = info.st_dev }
        let inode = Inode(device: info.st_dev, number: info.st_ino)
        guard !frames.contains(where: { $0.inode == inode }) else { fail("Directory cycle detected"); return }
        guard frames.count < 64 else { fail("Directory depth safety limit reached; last complete size retained"); return }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { fail("Directory cannot be opened (\(errno))"); return }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
            close(descriptor)
            fail("Directory changed while opening; last complete size retained")
            return
        }
        guard let stream = fdopendir(descriptor) else { close(descriptor); fail("Directory cannot be read (\(errno))"); return }
        add(info)
        guard observation.failure == nil else { closedir(stream); return }
        frames.append(Frame(path: path, stream: stream, device: info.st_dev, layoutDepth: layoutDepth, inode: inode))
    }

    private func add(_ info: stat) {
        // du semantics: allocated 512-byte blocks, one count per hard-linked inode.
        if info.st_mode & S_IFMT != S_IFDIR, info.st_nlink > 1 {
            guard hardLinks[info.st_dev]?.contains(info.st_ino) != true else { return }
            // Per-device 8-byte keys avoid storing every normal file/directory identity.
            // The explicit budget is roughly 16 MB of set storage per million hard-linked files.
            guard hardLinkCount < 1_000_000 else { fail("Hard-link memory budget reached; last complete size retained"); return }
            hardLinks[info.st_dev, default: []].insert(info.st_ino)
            hardLinkCount += 1
        }
        let blocks = Int64(info.st_blocks)
        let bytes = blocks.multipliedReportingOverflow(by: 512)
        let sum = observation.bytes.addingReportingOverflow(bytes.partialValue)
        guard blocks >= 0, !bytes.overflow, !sum.overflow else { fail("Size exceeds the supported range"); return }
        observation.bytes = sum.partialValue
        observation.entries += 1
    }

    private func fail(_ reason: String) {
        observation.failure = reason
        frames.removeAll()
    }
}

/// One queue means a slow filesystem can hold at most one metadata operation at a time.
/// A kernel-blocked syscall cannot be interrupted safely; the UI times out independently.
final class DirectorySizeExecutor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "HogHunter.directory-size", qos: .background)
    private var cursors: [String: DirectorySizeWalker] = [:]

    func discard(paths: [String]) {
        queue.async { [self] in
            for path in paths { cursors[path] = nil }
        }
    }

    func advance(path: String, startedAt: Date, pressured: Bool,
                 completion: @escaping @Sendable (DirectorySizeWalker.Observation) -> Void) {
        queue.async { [self] in
            let walker = cursors[path] ?? DirectorySizeWalker(path: path, startedAt: startedAt)
            cursors[path] = walker
            let observation = walker.advance(maxEntries: pressured ? 32 : 256, maxDuration: pressured ? 0.01 : 0.04)
            if observation.finishedAt != nil || observation.failure != nil { cursors[path] = nil }
            completion(observation)
        }
    }
}
#endif
