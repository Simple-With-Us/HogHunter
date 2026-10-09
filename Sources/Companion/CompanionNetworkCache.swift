import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// What one network scan produced for the phone.
struct CompanionNetworkScan: Equatable, Sendable {
    var rows: [CompanionNetworkRow]
    /// Why `rows` is empty or incomplete, in words the phone can show.
    var note: String?
}

/// The phone's Network tab.  Listing connections shells out to `lsof`, which is
/// far too heavy to run on every snapshot, so the host keeps the last result
/// and refreshes it on demand: the server asks for a refresh each time a phone
/// fetches a snapshot, and the cache scans only when its copy has gone stale.
/// Nothing runs while no phone is looking.
final class CompanionNetworkCache: @unchecked Sendable {
    static let shared = CompanionNetworkCache()

    /// Shown until the first scan lands, so the tab does not claim "no
    /// connections" about a scan that has not finished.
    static let scanningNote = "Looking for network connections on the Mac."

    private let lock = NSLock()
    private var scan = CompanionNetworkScan(rows: [], note: CompanionNetworkCache.scanningNote)
    private var scannedAt: Date?
    private var inFlight = false
    private let queue = DispatchQueue(label: "hoghunter.companion.network", qos: .utility)

    var current: CompanionNetworkScan {
        lock.lock()
        defer { lock.unlock() }
        return scan
    }

    var lastScannedAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return scannedAt
    }

    /// Scans in the background when the stored result is older than `maxAge`
    /// and no scan is already running.  `completion` runs on the scan queue
    /// once new rows are stored.
    func refreshIfStale(
        maxAge: TimeInterval = 20,
        now: Date = Date(),
        scan perform: @escaping @Sendable () -> CompanionNetworkScan = { CompanionSnapshotBuilder.currentNetworkScan() },
        completion: @escaping @Sendable () -> Void = {}
    ) {
        lock.lock()
        let stale = scannedAt.map { now.timeIntervalSince($0) >= maxAge } ?? true
        let start = stale && !inFlight
        if start { inFlight = true }
        lock.unlock()
        guard start else { return }
        queue.async { [self] in
            let result = perform()
            lock.lock()
            scan = result
            scannedAt = Date()
            inFlight = false
            lock.unlock()
            completion()
        }
    }

    /// Forgets the stored result.  For tests and for turning sharing off.
    func reset() {
        lock.lock()
        scan = CompanionNetworkScan(rows: [], note: Self.scanningNote)
        scannedAt = nil
        lock.unlock()
    }
}

extension CompanionSnapshotBuilder {
    /// The busiest connections first, capped so the snapshot stays small.
    static func networkRows(from usages: [NetworkUsage], limit: Int = 10) -> [CompanionNetworkRow] {
        usages
            .sorted { $0.establishedSockets > $1.establishedSockets }
            .prefix(limit)
            .map { usage in
                CompanionNetworkRow(
                    id: "\(usage.pid)",
                    name: usage.name,
                    pid: usage.pid,
                    establishedCount: usage.establishedSockets,
                    uniqueRemoteHosts: usage.remoteHostCount,
                    sampleRemoteHosts: usage.topRemoteHosts
                )
            }
    }

    /// Runs one `lsof` pass and packages it for the phone.
    static func currentNetworkScan(limit: Int = 10) -> CompanionNetworkScan {
        let scanner = NetworkScanner()
        let snapshot = scanner.snapshot { pid in
            #if canImport(AppKit)
            if let app = NSRunningApplication(processIdentifier: pid) {
                return (bundleId: app.bundleIdentifier, name: app.localizedName ?? "PID \(pid)")
            }
            #endif
            return (bundleId: nil, name: "PID \(pid)")
        }
        switch snapshot {
        case let .snapshot(_, usages):
            return CompanionNetworkScan(rows: networkRows(from: usages, limit: limit), note: nil)
        case let .unavailable(reason):
            return CompanionNetworkScan(rows: [], note: "The Mac could not list network connections.  \(reason)")
        }
    }
}
