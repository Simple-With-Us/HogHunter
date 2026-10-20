import Foundation

struct SizeGrowthSample: Codable, Equatable, Sendable {
    let bytes: Int64
    let sampledAt: Date
    var sourcePath: String? = nil
}

/// A bounded cache of observed sizes, never an extrapolation from a short interval.
final class SizeGrowthHistory: @unchecked Sendable {
    static let shared = SizeGrowthHistory()

    private struct Series: Codable, Sendable {
        var samples: [SizeGrowthSample]
    }
    private let lock = NSLock()
    private var series: [String: Series] = [:]
    private let writerQueue = DispatchQueue(label: "HogHunter.size-growth-writer", qos: .utility)
    private var pendingSnapshot: [String: Series]?
    private var writerScheduled = false
    private let fileURL: URL?
    private let now: () -> Date
    private let retention: TimeInterval = 48 * 3600
    private let bucket: TimeInterval = 15 * 60
    private let tolerance: TimeInterval = 15 * 60

    init(fileURL: URL? = SizeGrowthHistory.defaultURL, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        if let fileURL, let data = try? Data(contentsOf: fileURL), data.count <= 4_000_000,
           let decoded = try? JSONDecoder().decode([String: Series].self, from: data) {
            series = decoded
        }
        prune()
    }

    static var defaultURL: URL? {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] == nil,
              NSClassFromString("XCTestCase") == nil,
              NSClassFromString("XCTest.XCTestCase") == nil else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HogHunter/size-growth.json")
    }

    private func key(_ host: String, _ metric: String, _ path: String) -> String {
        // Length prefixes avoid collisions between host, metric, and path separators.
        [host, metric, path].map { "\($0.utf8.count):\($0)" }.joined()
    }

    @discardableResult
    func record(host: String, metric: String, path: String, bytes: Int64, sampledAt: Date, sourcePath: String? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let currentTime = now()
        guard !host.isEmpty, !metric.isEmpty, !path.isEmpty, bytes >= 0,
              sampledAt.timeIntervalSince1970.isFinite,
              sampledAt <= currentTime.addingTimeInterval(5 * 60),
              sampledAt >= currentTime.addingTimeInterval(-retention) else { return false }
        let id = key(host, metric, path)
        var samples = series[id]?.samples ?? []
        guard samples.last.map({ sampledAt > $0.sampledAt }) ?? true else { return false }
        if let last = samples.last,
           floor(last.sampledAt.timeIntervalSince1970 / bucket) == floor(sampledAt.timeIntervalSince1970 / bucket) {
            samples.removeLast()
        }
        samples.append(SizeGrowthSample(bytes: bytes, sampledAt: sampledAt, sourcePath: sourcePath))
        series[id] = Series(samples: samples)
        prune()
        schedulePersistence()
        return true
    }

    /// Import original source observations in one write, including missing history before the latest sample.
    @discardableResult
    func importSamples(host: String, metric: String, path: String, samples incoming: [SizeGrowthSample]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !host.isEmpty, !metric.isEmpty, !path.isEmpty else { return false }
        let currentTime = now()
        let cutoff = currentTime.addingTimeInterval(-retention)
        let futureLimit = currentTime.addingTimeInterval(5 * 60)
        let id = key(host, metric, path)
        let existing = series[id]?.samples ?? []
        var buckets: [Int64: SizeGrowthSample] = [:]
        // Existing observations win ties, so a repeated source timestamp cannot rewrite its value.
        for sample in existing + incoming.prefix(10_000) {
            guard sample.bytes >= 0, sample.sampledAt.timeIntervalSince1970.isFinite,
                  sample.sampledAt >= cutoff, sample.sampledAt <= futureLimit else { continue }
            let bucketID = Int64(floor(sample.sampledAt.timeIntervalSince1970 / bucket))
            if let previous = buckets[bucketID], previous.sampledAt >= sample.sampledAt { continue }
            buckets[bucketID] = sample
        }
        let merged = Array(buckets.values.sorted { $0.sampledAt < $1.sampledAt }.suffix(193))
        guard !merged.isEmpty, merged != existing else { return false }
        series[id] = Series(samples: merged)
        prune()
        schedulePersistence()
        return true
    }

    func latest(host: String, metric: String, path: String) -> SizeGrowthSample? {
        lock.lock()
        defer { lock.unlock() }
        return series[key(host, metric, path)]?.samples.last
    }

    func percentChange(host: String, metric: String, path: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let samples = series[key(host, metric, path)]?.samples,
              let latest = samples.last,
              now().timeIntervalSince(latest.sampledAt) <= 3600 else { return nil }
        let target = latest.sampledAt.addingTimeInterval(-24 * 3600)
        guard let baseline = samples.dropLast().filter({
            // Allow timestamp precision drift, rather than calling 23 hours a full day.
            latest.sampledAt.timeIntervalSince($0.sampledAt) >= 24 * 3600 - 60
                && abs($0.sampledAt.timeIntervalSince(target)) <= tolerance
        })
            .min(by: { abs($0.sampledAt.timeIntervalSince(target)) < abs($1.sampledAt.timeIntervalSince(target)) }),
              baseline.bytes > 0 else { return nil }
        return (Double(latest.bytes) - Double(baseline.bytes)) / Double(baseline.bytes) * 100
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-retention)
        series = series.compactMapValues { value in
            let samples = Array(value.samples.filter { $0.bytes >= 0 && $0.sampledAt >= cutoff && $0.sampledAt <= now().addingTimeInterval(300) }
                .sorted { $0.sampledAt < $1.sampledAt }.suffix(193))
            return samples.isEmpty ? nil : Series(samples: samples)
        }
        if series.count > 256 {
            let keep = Set(series.sorted { ($0.value.samples.last?.sampledAt ?? .distantPast) > ($1.value.samples.last?.sampledAt ?? .distantPast) }.prefix(256).map(\.key))
            series = series.filter { keep.contains($0.key) }
        }
    }

    /// Called under `lock`.  Copy-on-write captures a coherent immutable value; encoding
    /// and disk I/O never hold the history lock or run on the caller's actor.
    private func schedulePersistence() {
        guard fileURL != nil else { return }
        pendingSnapshot = series
        guard !writerScheduled else { return }
        writerScheduled = true
        writerQueue.async { [self] in
            while true {
                lock.lock()
                guard let snapshot = pendingSnapshot else {
                    writerScheduled = false
                    lock.unlock()
                    return
                }
                pendingSnapshot = nil
                lock.unlock()
                // One serial writer guarantees an older snapshot cannot overwrite a newer one.
                guard let fileURL, let data = try? JSONEncoder().encode(snapshot) else { continue }
                do {
                    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: fileURL, options: .atomic)
                } catch {
                    // Atomic replacement preserves the last good file.  The next mutation retries.
                }
            }
        }
    }

    /// Deterministic test/export barrier.  UI paths must never wait for disk persistence.
    func flushPersistence() {
        writerQueue.sync {}
    }

}

enum SizeGrowthFormat {
    static func appreciableDelta(_ percent: Double?) -> String? {
        guard let percent, percent.isFinite, abs(percent) >= 0.1 else { return nil }
        return delta(percent)
    }

    static func delta(_ percent: Double?) -> String? {
        guard let percent, percent.isFinite else { return nil }
        let magnitude = abs(percent)
        guard magnitude >= 0.1 else { return "~0%" }
        let digits = magnitude < 10 ? 1.0 : 2.0
        let scale = pow(10.0, digits - 1 - floor(log10(magnitude)))
        let rounded = (magnitude * scale).rounded() / scale
        let decimals = max(0, Int(digits - 1 - floor(log10(rounded))))
        let value = String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), decimals, rounded)
        return percent < 0 ? "↓-\(value)%" : "↑\(value)%"
    }
}
