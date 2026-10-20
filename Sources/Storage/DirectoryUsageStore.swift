#if os(macOS)
import Foundation
import Combine
import Darwin

struct DirectoryUsageRow: Identifiable, Equatable {
    var id: String { displayPath }
    let title: String
    var path: String
    let displayPath: String
    var bytes: Int64?
    var sampledAt: Date?
    var percentChange: Double?
    var isUnavailable = false
    var progressBytes: Int64 = 0
    var progressEntries = 0
    var scanStartedAt: Date?
    var completedAt: Date?
    var statusText = "Waiting to measure"
    var nextAttempt = Date.distantPast
    var hasResolvedPath = false
}

@MainActor
final class DirectoryUsageStore: ObservableObject {
    typealias Probe = @Sendable (String) -> Int64?
    enum Pressure: Equatable { case normal, reduced, paused(String) }
    @Published private(set) var rows: [DirectoryUsageRow]
    @Published private(set) var isRefreshing = false
    private let history: SizeGrowthHistory
    private let probe: Probe?
    private let now: () -> Date
    private let pressure: () -> Pressure
    private let idlePressure: () -> Pressure
    private(set) var isMeasurementEnabled = true
    private let host: String
    private let allowsMeasurement: Bool
    private let executor = DirectorySizeExecutor()
    private var nextIndex = 0
    private var pending: Pending?

    /// The callback never waits for MainActor; a blocked metadata call stays on one background queue.
    private final class Pending: @unchecked Sendable {
        let id: String
        let requestedAt = ProcessInfo.processInfo.systemUptime
        private let lock = NSLock()
        private var value: DirectorySizeWalker.Observation?
        init(id: String) { self.id = id }
        func put(_ result: DirectorySizeWalker.Observation) { lock.lock(); value = result; lock.unlock() }
        func get() -> DirectorySizeWalker.Observation? { lock.lock(); defer { lock.unlock() }; return value }
    }

    init(history: SizeGrowthHistory = .shared,
         candidates: [(title: String, path: String)]? = nil,
         host: String = "mac-local", now: @escaping () -> Date = Date.init,
         probe: Probe? = nil, pressure: @escaping () -> Pressure = { DirectoryUsageStore.currentPressure() },
         idlePressure: @escaping () -> Pressure = { DirectoryUsageStore.currentIdlePressure() }) {
        self.history = history
        self.probe = probe
        self.now = now
        self.host = host
        self.pressure = pressure
        self.idlePressure = idlePressure
        allowsMeasurement = candidates != nil || (ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            && NSClassFromString("XCTestCase") == nil && NSClassFromString("XCTest.XCTestCase") == nil)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let defaults = [("Code", "\(home)/Code"), ("Coding Lanes", "\(home)/apps/lanes"),
                        ("Codex", "\(home)/.codex"), ("Claude", "\(home)/.claude"),
                        ("MiniMax", "\(home)/.minimax"), ("MiniMax Code", "\(home)/.minimax-code"),
                        ("npm Cache", "\(home)/.npm"), ("Derived Data", "\(home)/Library/Developer/Xcode/DerivedData"),
                        ("Caches", "\(home)/.cache"), ("Temporary Files", "/private/tmp")]
        var accepted = Set<String>()
        rows = (candidates ?? defaults).compactMap { title, path in
            let logical = URL(fileURLWithPath: path).standardizedFileURL.path
            guard accepted.insert(logical).inserted else { return nil }
            let sample = history.latest(host: host, metric: "directory", path: logical)
            let source = sample?.sourcePath ?? logical
            return DirectoryUsageRow(title: title, path: source, displayPath: path, bytes: sample?.bytes,
                                     sampledAt: sample?.sampledAt,
                                     percentChange: history.percentChange(host: host, metric: "directory", path: source),
                                     isUnavailable: sample.map { now().timeIntervalSince($0.sampledAt) > 3600 } ?? false)
        }
    }

    /// Retry unfinished cursors promptly; completed rows stay on a start-to-start 15-minute cadence.
    var nextRefreshDelay: TimeInterval {
        if pending != nil { return 1 }
        return max(1, min(900, rows.map { $0.nextAttempt.timeIntervalSince(now()) }.min() ?? 900))
    }

    func setMeasurementEnabled(_ enabled: Bool) {
        isMeasurementEnabled = enabled
        if !enabled {
            for index in rows.indices where rows[index].scanStartedAt != nil {
                rows[index].statusText = "Measurement paused; progress retained"
            }
        }
    }

    /// The app owns this continuation separately from any view-triggered work.
    func refreshWhenIdle() async {
        await refreshIfNeeded(background: true)
    }

    /// Short, fair bursts.  Cancellation retains the cursor but queues no more I/O.
    func refreshIfNeeded(force: Bool = false, background: Bool = false) async {
        guard !isRefreshing, allowsMeasurement, isMeasurementEnabled else { return }
        isRefreshing = true
        for index in rows.indices {
            rows[index].percentChange = history.percentChange(host: host, metric: "directory", path: rows[index].path)
            if let sampledAt = rows[index].sampledAt, now().timeIntervalSince(sampledAt) > 3600 {
                rows[index].isUnavailable = true
            }
        }
        defer {
            isRefreshing = false
            if Task.isCancelled {
                for index in rows.indices where rows[index].scanStartedAt != nil {
                    rows[index].statusText = "Measurement paused; progress retained"
                }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var forced = Set<String>()
        while !Task.isCancelled, isMeasurementEnabled, !rows.isEmpty, ProcessInfo.processInfo.systemUptime < deadline {
            if let request = pending {
                if let result = request.get() {
                    pending = nil
                    apply(result, id: request.id)
                } else {
                    if ProcessInfo.processInfo.systemUptime - request.requestedAt >= 1,
                       let index = rows.firstIndex(where: { $0.id == request.id }) {
                        rows[index].statusText = "Waiting on slow disk I/O; progress retained"
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                    continue
                }
            }
            let currentPressure = background ? idlePressure() : pressure()
            if case .paused(let reason) = currentPressure {
                for index in rows.indices where rows[index].nextAttempt <= now() {
                    rows[index].statusText = reason
                    if !background { rows[index].nextAttempt = now().addingTimeInterval(15) }
                }
                return
            }
            var selected: Int?
            for offset in 0..<rows.count {
                let index = (nextIndex + offset) % rows.count
                if force ? !forced.contains(rows[index].id) : rows[index].nextAttempt <= now() { selected = index; break }
            }
            guard let index = selected else { return }
            nextIndex = (index + 1) % rows.count
            forced.insert(rows[index].id)
            let path = rows[index].displayPath
            let request = Pending(id: rows[index].id)
            let start = rows[index].scanStartedAt ?? now()
            rows[index].scanStartedAt = start
            rows[index].statusText = currentPressure == .reduced ? "Measuring slowly under system load" : "Measuring"
            pending = request
            if let probe {
                // Compatibility seam for deterministic tests; production uses resumable metadata slices.
                DispatchQueue.global(qos: .background).async {
                    let bytes = probe(path).flatMap { $0 >= 0 ? $0 : nil }
                    request.put(.init(path: path, bytes: bytes ?? 0, entries: 0, startedAt: start,
                                      finishedAt: bytes == nil ? nil : start,
                                      failure: bytes == nil ? "Size could not be measured" : nil,
                                      hasResolvedRoot: bytes != nil))
                }
            } else {
                executor.advance(path: path, startedAt: start, pressured: currentPressure == .reduced) { request.put($0) }
            }
            // One slice at a time, with idle time between bursts, especially under pressure.
            try? await Task.sleep(for: .milliseconds(currentPressure == .reduced ? 250 : 30))
        }
    }

    private func apply(_ result: DirectorySizeWalker.Observation, id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        if result.hasResolvedRoot, rows[index].path != result.path {
            // A retargeted alias must not inherit the previous target's cached total or delta.
            rows[index].bytes = nil
            rows[index].sampledAt = nil
            rows[index].completedAt = nil
            rows[index].percentChange = nil
        }
        if result.hasResolvedRoot {
            rows[index].path = result.path
            rows[index].hasResolvedPath = true
            if rows[index].bytes == nil, let sample = history.latest(host: host, metric: "directory", path: result.path) {
                rows[index].bytes = sample.bytes
                rows[index].sampledAt = sample.sampledAt
                rows[index].percentChange = history.percentChange(host: host, metric: "directory", path: result.path)
            }
        } else {
            rows[index].hasResolvedPath = false
        }
        rows[index].progressBytes = result.bytes
        rows[index].progressEntries = result.entries
        if let failure = result.failure {
            rows[index].isUnavailable = true
            rows[index].percentChange = nil
            rows[index].statusText = failure + "; retry in one minute"
            rows[index].scanStartedAt = nil
            rows[index].nextAttempt = now().addingTimeInterval(60)
        } else if result.isComplete {
            // The source time is the start of this observation, never the later cache/write time.
            history.record(host: host, metric: "directory", path: result.path, bytes: result.bytes, sampledAt: result.startedAt)
            rows[index].bytes = result.bytes
            rows[index].sampledAt = result.startedAt
            rows[index].percentChange = history.latest(host: host, metric: "directory", path: result.path)?.sampledAt == result.startedAt
                ? history.percentChange(host: host, metric: "directory", path: result.path) : nil
            // Also cache the logical alias, so reopening can show a last good value before a slow
            // symlink/volume resolves.  Comparisons still use the canonical source identity.
            if result.path != rows[index].displayPath {
                let alias = URL(fileURLWithPath: rows[index].displayPath).standardizedFileURL.path
                history.record(host: host, metric: "directory", path: alias,
                               bytes: result.bytes, sampledAt: result.startedAt, sourcePath: result.path)
            }
            rows[index].isUnavailable = now().timeIntervalSince(result.startedAt) > 3600
            rows[index].completedAt = result.finishedAt
            rows[index].scanStartedAt = nil
            rows[index].statusText = "Complete"
            rows[index].nextAttempt = Self.nextScheduledAttempt(startedAt: result.startedAt, now: now())
        } else {
            rows[index].nextAttempt = .distantPast
        }
        // Canonicalization and alias/ancestor dedup happen after the background resolution.
        if result.hasResolvedRoot {
            let canonical = result.path
            let discarded: [String]
            if rows.contains(where: { $0.id != id && $0.hasResolvedPath
                && (canonical == $0.path || canonical.hasPrefix($0.path + "/")) }) {
                discarded = rows.filter { $0.id == id }.map(\.displayPath)
                rows.removeAll { $0.id == id }
            } else {
                discarded = rows.filter { $0.id != id && $0.hasResolvedPath && $0.path.hasPrefix(canonical + "/") }.map(\.displayPath)
                rows.removeAll { $0.id != id && $0.hasResolvedPath && $0.path.hasPrefix(canonical + "/") }
            }
            if !discarded.isEmpty { executor.discard(paths: discarded) }
        }
        if !rows.isEmpty { nextIndex %= rows.count }
    }

    /// Skip missed slots after a long walk instead of drifting by its duration or overlapping it.
    nonisolated static func nextScheduledAttempt(startedAt: Date, now: Date) -> Date {
        let slots = floor(max(0, now.timeIntervalSince(startedAt)) / 900) + 1
        return startedAt.addingTimeInterval(slots * 900)
    }

    nonisolated static func currentPressure() -> Pressure {
        var memory: Int32 = 0
        var length = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &memory, &length, nil, 0) == 0 else { return .reduced }
        if memory == 4 || ProcessInfo.processInfo.thermalState == .critical {
            return .paused("Paused for critical system pressure; progress retained")
        }
        var load = 0.0
        _ = getloadavg(&load, 1)
        return memory == 2 || ProcessInfo.processInfo.thermalState == .serious
            || load > Double(ProcessInfo.processInfo.activeProcessorCount) * 1.5 ? .reduced : .normal
    }

    nonisolated static func currentIdlePressure() -> Pressure {
        let current = currentPressure()
        if case .paused = current { return current }
        guard current == .normal else { return .paused("Awaiting an idle Mac; progress retained") }
        var load = 0.0
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard getloadavg(&load, 1) == 1, sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 else {
            return .paused("Awaiting readable system pressure; progress retained")
        }
        let swapPercent = swap.xsu_total > 0 ? 100 * Double(swap.xsu_used) / Double(swap.xsu_total) : 0
        return idlePressure(base: current, load: load, swapUsedPercent: swapPercent,
                            processorCount: ProcessInfo.processInfo.activeProcessorCount)
    }

    nonisolated static func idlePressure(base: Pressure, load: Double?, swapUsedPercent: Double?, processorCount: Int) -> Pressure {
        if case .paused = base { return base }
        guard base == .normal else { return .paused("Awaiting an idle Mac; progress retained") }
        guard let load, let swapUsedPercent, load.isFinite, swapUsedPercent.isFinite else {
            return .paused("Awaiting readable system pressure; progress retained")
        }
        guard load < min(4, Double(max(1, processorCount)) / 2), swapUsedPercent < 90 else {
            return .paused("Awaiting lower CPU load and swap use; progress retained")
        }
        return .normal
    }

    /// Enumerate only two layout levels, never repository contents or recursive links.
    /// `du` does not follow child symlinks, so external lane targets need explicit roots.
    nonisolated static func measurementRoots(_ path: String, includeLaneLinks: Bool) -> [String]? {
        let manager = FileManager.default
        let base = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: base.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        guard includeLaneLinks else { return [base.path] }
        func contains(_ parent: String, _ child: String) -> Bool {
            parent == child || child.hasPrefix(parent + "/")
        }
        var external: [String] = []
        do {
            let children = try manager.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard children.count <= 2048 else { return nil }
            var candidates = children
            for child in children {
                let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                if values.isDirectory == true && values.isSymbolicLink != true {
                    let nested = try manager.contentsOfDirectory(at: child, includingPropertiesForKeys: [.isSymbolicLinkKey])
                    guard nested.count <= 4096 else { return nil }
                    candidates.append(contentsOf: nested)
                    guard candidates.count <= 8192 else { return nil }
                }
            }
            for child in candidates {
                let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink == true else { continue }
                let target = child.resolvingSymlinksInPath().standardizedFileURL.path
                var directory: ObjCBool = false
                guard manager.fileExists(atPath: target, isDirectory: &directory), directory.boolValue else { continue }
                // Local aliases are already counted; ancestor links would traverse unrelated data.
                guard !contains(base.path, target), !contains(target, base.path) else { continue }
                if external.contains(where: { contains($0, target) }) { continue }
                external.removeAll(where: { contains(target, $0) })
                external.append(target)
                guard external.count <= 128 else { return nil }
            }
        } catch { return nil }
        return [base.path] + external.sorted()
    }

    nonisolated static func measuredBytes(_ output: String, roots: [String]) -> Int64? {
        var values: [String: Int64] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, let kibibytes = Int64(fields[0]), kibibytes >= 0,
                  roots.contains(String(fields[1])), values[String(fields[1])] == nil,
                  kibibytes <= Int64.max / 1024 else { return nil }
            values[String(fields[1])] = kibibytes * 1024
        }
        guard values.count == roots.count else { return nil }
        var total: Int64 = 0
        for value in values.values {
            let sum = total.addingReportingOverflow(value)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }

}
#endif
