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
        var hasResolvedRoot = false
        var retryAutomatically = true
        var isComplete: Bool { finishedAt != nil && failure == nil }
    }

    private struct Inode: Hashable {
        let device: dev_t
        let number: ino_t
    }
    private struct LinkedRoot {
        let path: String
        let inode: Inode
        let kind: mode_t
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
    private var followedLinks: [String: LinkedRoot] = [:]
    private var linkChecks: [(String, LinkedRoot)]?
    private var nextLinkCheck = 0
    private var baseIdentity: Inode?
    private var initialized = false
    private let includesLaneLinks: Bool
    /// Retained because `observation.path` becomes the physical root after the first slice.
    private let logicalPath: String
    private let allowsPath: (String) -> Bool
    private let willReadMetadata: (String) -> Void
    static let automaticAccessReason = "External or network directory not measured automatically"

    /// Check the kernel's mount names before any directory metadata or symlink target is read.
    /// In particular, realpath() follows a local alias onto a protected volume before returning.
    static func automaticAccessPolicy(mountPaths: [String]) -> (String) -> Bool {
        let protected = ["/Volumes"] + mountPaths.filter {
            $0 != "/" && $0 != "/dev" && !$0.hasPrefix("/System/Volumes/")
        }
        return { path in
            !protected.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
    }

    init(path: String, startedAt: Date,
         allowsPath: ((String) -> Bool)? = nil,
         willReadMetadata: @escaping (String) -> Void = { _ in }) {
        observation = Observation(path: path, bytes: 0, entries: 0, startedAt: startedAt)
        includesLaneLinks = URL(fileURLWithPath: path).lastPathComponent == "lanes"
        logicalPath = path
        self.allowsPath = allowsPath ?? Self.automaticAccessPolicy(
            mountPaths: MountedDriveStore.cachedMountRecords().map(\.path))
        self.willReadMetadata = willReadMetadata
    }

    func advance(maxEntries: Int = 256, maxDuration: TimeInterval = 0.04) -> Observation {
        guard observation.failure == nil, observation.finishedAt == nil else { return observation }
        let deadline = ProcessInfo.processInfo.systemUptime + maxDuration
        if !initialized {
            initialized = true
            // Resolution can touch a slow volume, so it belongs here, never in a view initializer.
            guard let physicalPath = canonicalPath(observation.path) else {
                if observation.failure == nil { fail("Directory cannot be resolved (\(errno))") }
                return observation
            }
            observation.path = physicalPath
            enter(observation.path, expectedDevice: nil, layoutDepth: includesLaneLinks ? 0 : nil, isRoot: true)
            observation.hasResolvedRoot = observation.failure == nil
            baseIdentity = frames.first?.inode
        }
        if let frame = frames.last, !validate(frame) { return observation }
        var processed = 0
        while observation.failure == nil, let frame = frames.last,
              processed < maxEntries, ProcessInfo.processInfo.systemUptime < deadline {
            errno = 0
            guard let entry = readdir(frame.stream) else {
                let error = errno
                guard validate(frame) else { continue }
                frames.removeLast()
                if error != 0 {
                    errno = error
                    failIfPermissionDenied()
                    fail("Could not read every directory entry (\(error))")
                }
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
            guard readMetadata(path, into: &info) == 0 else {
                // A disappearing entry is a normal concurrent mutation, never a permission bypass.
                if errno != ENOENT { fail("Could not read metadata (\(errno))") }
                else { _ = validate(frame) }
                continue
            }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFDIR {
                enter(path, expectedDevice: frame.device, layoutDepth: frame.layoutDepth.map { $0 + 1 }, info: info)
            } else {
                add(info)
                if kind == S_IFLNK, let depth = frame.layoutDepth, depth < 2 {
                    guard let target = canonicalPath(path) else {
                        if observation.failure == nil { fail("Linked directory cannot be resolved (\(errno))") }
                        continue
                    }
                    var targetInfo = stat()
                    guard readMetadata(target, into: &targetInfo) == 0 else {
                        fail("Linked directory is unavailable (\(errno))")
                        continue
                    }
                    // Track aliases even when their target is already covered or is an ancestor.
                    // Retargeting one later must invalidate the aggregate before it is published.
                    guard followedLinks.count < 4096 else { fail("Linked-root safety limit reached; last complete size retained"); continue }
                    followedLinks[path] = LinkedRoot(path: target,
                        inode: Inode(device: targetInfo.st_dev, number: targetInfo.st_ino),
                        kind: targetInfo.st_mode & S_IFMT)
                    // Only explicit layout links may cross a volume.  Repository symlinks stay leaves.
                    if targetInfo.st_mode & S_IFMT == S_IFDIR,
                       target != observation.path, !observation.path.hasPrefix(target + "/") {
                        guard !Self.isCovered(path: target, device: targetInfo.st_dev, roots: countedRoots) else { continue }
                        // Keep earlier child partitions when a broader root appears later.
                        // Walking that parent skips those boundaries, counting only its extra data.
                        guard countedRoots.count < 4096 else { fail("Linked-root safety limit reached; last complete size retained"); continue }
                        enter(target, expectedDevice: nil, layoutDepth: nil, info: targetInfo, isRoot: true)
                    }
                }
            }
        }
        if observation.failure == nil, frames.isEmpty {
            // Final link checks share the slice budget and resume across calls, even for many aliases.
            if linkChecks == nil { linkChecks = Array(followedLinks) }
            while let checks = linkChecks, nextLinkCheck < checks.count,
                  processed < maxEntries, ProcessInfo.processInfo.systemUptime < deadline {
                let (link, expected) = checks[nextLinkCheck]
                processed += 1
                var info = stat()
                guard canonicalPath(link) == expected.path, readMetadata(expected.path, into: &info) == 0,
                      info.st_mode & S_IFMT == expected.kind,
                      info.st_dev == expected.inode.device, info.st_ino == expected.inode.number else {
                    fail("Linked lane target changed or became unavailable while measuring")
                    return observation
                }
                nextLinkCheck += 1
            }
            guard nextLinkCheck == linkChecks?.count, processed < maxEntries,
                  ProcessInfo.processInfo.systemUptime < deadline else { return observation }
            // A logical symlink can be retargeted while a long walk runs.  The open frames still
            // validate, but the total belongs to the old target, so it must not be published under
            // the alias the row is displayed by.  Re-resolving here keeps the syscall off the caller.
            var rootInfo = stat()
            guard canonicalPath(logicalPath) == observation.path,
                  readMetadata(observation.path, into: &rootInfo) == 0,
                  baseIdentity == Inode(device: rootInfo.st_dev, number: rootInfo.st_ino) else {
                fail("Symlink target changed while measuring")
                return observation
            }
            observation.finishedAt = Date()
        }
        return observation
    }

    /// Foundation may shorten /private/tmp back to the /tmp symlink after resolution.
    /// Keep the POSIX physical path so the root passes lstat and O_NOFOLLOW checks.
    static func canonicalPath(_ path: String) -> String? {
        resolvePath(path, allowsPath: { _ in true }, willReadMetadata: { _ in })
    }

    /// Shared non-interactive preflight for background inventory readers.
    static func automaticCanonicalPath(_ path: String, mountPaths: [String]) -> String? {
        resolvePath(path, allowsPath: automaticAccessPolicy(mountPaths: mountPaths), willReadMetadata: { _ in })
    }

    private func canonicalPath(_ path: String) -> String? {
        let result = Self.resolvePath(path, allowsPath: { [self] candidate in
            guard allowsPath(candidate) else {
                fail(Self.automaticAccessReason, retryAutomatically: false)
                return false
            }
            return true
        }, willReadMetadata: willReadMetadata)
        if result == nil { failIfPermissionDenied() }
        return result
    }

    private func failIfPermissionDenied() {
        if errno == EACCES || errno == EPERM {
            fail("Directory access denied; automatic measurement paused", retryAutomatically: false)
        }
    }

    /// Resolve local link text first, then gate the destination before lstat can follow it.
    /// Do not standardize away `..` before resolving a symlink: POSIX applies it to the target.
    private static func resolvePath(_ path: String, allowsPath: (String) -> Bool,
                                    willReadMetadata: (String) -> Void) -> String? {
        guard path.hasPrefix("/") else { errno = EINVAL; return nil }
        var remaining = path.split(separator: "/").map(String.init)
        var resolved: [String] = []
        var links = 0
        while !remaining.isEmpty {
            let component = remaining.removeFirst()
            if component == "." { continue }
            if component == ".." { if !resolved.isEmpty { resolved.removeLast() }; continue }
            let candidate = "/" + (resolved + [component]).joined(separator: "/")
            guard allowsPath(candidate) else { errno = EACCES; return nil }
            willReadMetadata(candidate)
            var info = stat()
            guard lstat(candidate, &info) == 0 else { return nil }
            if info.st_mode & S_IFMT == S_IFLNK {
                links += 1
                guard links <= 40 else { errno = ELOOP; return nil }
                // destinationOfSymbolicLink reads the link itself, never its destination.
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) else { return nil }
                if target.hasPrefix("/") { resolved.removeAll() }
                remaining = target.split(separator: "/").map(String.init) + remaining
            } else {
                resolved.append(component)
            }
        }
        let result = "/" + resolved.joined(separator: "/")
        guard allowsPath(result) else { errno = EACCES; return nil }
        return result
    }

    private func readMetadata(_ path: String, into info: inout stat) -> Int32 {
        guard allowsPath(path) else {
            fail(Self.automaticAccessReason, retryAutomatically: false)
            errno = EACCES
            return -1
        }
        willReadMetadata(path)
        let result = lstat(path, &info)
        if result != 0 { failIfPermissionDenied() }
        return result
    }

    /// A same-device parent covers descendants; a nested mounted volume is excluded
    /// by normal traversal and must still be accepted through its explicit lane link.
    static func isCovered(path: String, device: dev_t, roots: [String: dev_t]) -> Bool {
        roots.contains { root, rootDevice in
            device == rootDevice && (path == root || path.hasPrefix(root + "/"))
        }
    }

    /// An open stream can outlive a rename while its absolute child paths disappear.
    /// Never publish those skipped children as a complete, smaller observation.
    private func validate(_ frame: Frame) -> Bool {
        var info = stat()
        guard readMetadata(frame.path, into: &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_dev == frame.inode.device, info.st_ino == frame.inode.number else {
            fail("Directory moved or changed while measuring; last complete size retained")
            return false
        }
        return true
    }

    private func enter(_ path: String, expectedDevice: dev_t?, layoutDepth: Int?, info supplied: stat? = nil,
                       isRoot: Bool = false) {
        guard isRoot || countedRoots[path] == nil else { return }
        var info = supplied ?? stat()
        if supplied == nil, readMetadata(path, into: &info) != 0 { fail("Directory is unavailable (\(errno))"); return }
        guard info.st_mode & S_IFMT == S_IFDIR else { fail("Path is not a directory"); return }
        guard expectedDevice == nil || expectedDevice == info.st_dev else { return }
        if isRoot { countedRoots[path] = info.st_dev }
        let inode = Inode(device: info.st_dev, number: info.st_ino)
        guard !frames.contains(where: { $0.inode == inode }) else { fail("Directory cycle detected"); return }
        guard frames.count < 64 else { fail("Directory depth safety limit reached; last complete size retained"); return }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            failIfPermissionDenied()
            fail("Directory cannot be opened (\(errno))")
            return
        }
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

    private func fail(_ reason: String, retryAutomatically: Bool = true) {
        // Retain the first failure and its retry policy when a failed safety check unwinds.
        guard observation.failure == nil else { return }
        observation.failure = reason
        observation.retryAutomatically = retryAutomatically
        frames.removeAll()
    }
}

/// One queue means a slow filesystem can hold at most one metadata operation at a time.
/// A kernel-blocked syscall cannot be interrupted safely; the UI times out independently.
final class DirectorySizeExecutor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "HogHunter.directory-size", qos: .background)
    private var cursors: [String: DirectorySizeWalker] = [:]
    typealias WalkerFactory = @Sendable (String, Date, Bool) -> DirectorySizeWalker
    private let makeWalker: WalkerFactory

    init(makeWalker: @escaping WalkerFactory = { path, startedAt, allowExternal in
        DirectorySizeWalker(path: path, startedAt: startedAt,
                            allowsPath: allowExternal ? { _ in true } : nil)
    }) {
        self.makeWalker = makeWalker
    }

    func discard(paths: [String]) {
        queue.async { [self] in
            for path in paths { cursors[path] = nil }
        }
    }

    func advance(path: String, startedAt: Date, pressured: Bool, allowExternal: Bool = false,
                 completion: @escaping @Sendable (DirectorySizeWalker.Observation) -> Void) {
        queue.async { [self] in
            let walker = cursors[path] ?? makeWalker(path, startedAt, allowExternal)
            cursors[path] = walker
            let observation = walker.advance(maxEntries: pressured ? 32 : 256, maxDuration: pressured ? 0.01 : 0.04)
            if observation.finishedAt != nil || observation.failure != nil { cursors[path] = nil }
            completion(observation)
        }
    }
}
#endif
