import Darwin
import Foundation
import SwiftUI

/// Cumulative bytes moved by every active network interface.
///
/// macOS exposes this through `getifaddrs`: each `AF_LINK` entry carries an
/// `if_data` whose `ifi_ibytes` / `ifi_obytes` are lifetime byte counters.
/// They only ever go up, so a rate is a difference between two readings, not a
/// value in itself.
struct InterfaceCounters: Equatable {
    var received: UInt64
    var sent: UInt64
}

/// Reads the kernel's per-interface byte counters.
///
/// Deliberately sums every interface that is up and is not loopback, rather
/// than picking Wi-Fi: on a Mac with a Thunderbolt bridge, a VPN, or both, the
/// busiest interface is not always `en0`, and a panel that only counted Wi-Fi
/// would read zero while the machine was moving gigabytes.
enum InterfaceTraffic {
    /// Nil when the interface list itself could not be read, which the caller
    /// must not confuse with "no traffic".
    static func counters() -> InterfaceCounters? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor?.pointee {
            cursor = interface.ifa_next
            guard let address = interface.ifa_addr, let data = interface.ifa_data else { continue }
            // `ifa_data` is only an `if_data` on an `AF_LINK` entry.  Reading it
            // on any other family would reinterpret a different struct as this
            // one and print nonsense.
            guard address.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            received &+= UInt64(stats.ifi_ibytes)
            sent &+= UInt64(stats.ifi_obytes)
        }
        return InterfaceCounters(received: received, sent: sent)
    }
}

/// One rate reading, plus whether it is a real measurement yet.
struct BandwidthReading: Equatable {
    var downBytesPerSecond: Double
    var upBytesPerSecond: Double
    /// The window the two rates were averaged over.
    var windowSeconds: TimeInterval
    /// False until two readings far enough apart exist to difference.
    var isMeasured: Bool

    static let pending = BandwidthReading(
        downBytesPerSecond: 0,
        upBytesPerSecond: 0,
        windowSeconds: 0,
        isMeasured: false
    )
}

extension BandwidthReading {
    /// The caption under the "Now" card.  Shared by the Network tab and the
    /// phone so the two never word it differently.
    var footnote: String {
        guard isMeasured else { return "Measuring…" }
        return "Last \(Int(windowSeconds.rounded())) s"
    }
}

/// Turns cumulative counters into a rate by differencing readings.
///
/// A single-sample difference is far too jumpy to put on screen: one counter
/// read either side of a packet burst reads as a spike and then zero forever
/// after.  This keeps a short ring of readings and reports the average over
/// the whole ring, which is both steadier and an honest statement of what the
/// rate was over the last few seconds.
struct BandwidthTracker {
    /// Readings kept.  At the 5 s cadence `BandwidthStore` uses, six readings
    /// is a 25 s window.
    static var windowSize: Int { 6 }

    private struct Sample {
        var at: Date
        var counters: InterfaceCounters
    }

    private var samples: [Sample] = []
    private(set) var reading: BandwidthReading = .pending

    /// Adds one counter reading and returns the new rate.
    ///
    /// A counter that moved *backwards* means an interface was re-created (a
    /// Wi-Fi reconnect, a VPN cycling, a USB adapter re-enumerating) rather
    /// than traffic.  Differencing across that would print a negative spike,
    /// so the ring is dropped and the measurement restarts from here.
    mutating func ingest(_ counters: InterfaceCounters, at date: Date) -> BandwidthReading {
        if let last = samples.last, counters.received < last.counters.received || counters.sent < last.counters.sent {
            samples.removeAll()
        }
        samples.append(Sample(at: date, counters: counters))
        if samples.count > Self.windowSize { samples.removeFirst(samples.count - Self.windowSize) }

        guard let first = samples.first, let last = samples.last, samples.count >= 2 else {
            reading = .pending
            return reading
        }
        let seconds = last.at.timeIntervalSince(first.at)
        // Two readings a few hundred milliseconds apart differencing a counter
        // that ticks at gigabytes per second is mostly rounding error.
        guard seconds >= 1 else {
            reading = .pending
            return reading
        }
        reading = BandwidthReading(
            downBytesPerSecond: Double(last.counters.received - first.counters.received) / seconds,
            upBytesPerSecond: Double(last.counters.sent - first.counters.sent) / seconds,
            windowSeconds: seconds,
            isMeasured: true
        )
        return reading
    }
}

/// Peak and total traffic over a window, as read back out of the history
/// database.  Survives restarts, so "24-hour peak" means the last 24 hours of
/// wall-clock time rather than the last 24 hours Hog Hunter happened to be
/// open.
struct NetworkPeaks: Equatable {
    var peakDownBytesPerSecond: Double
    var peakUpBytesPerSecond: Double
    var peakAt: Date?
    var totalDownBytes: UInt64
    var totalUpBytes: UInt64
    var sampledSeconds: TimeInterval
    var hasSamples: Bool

    static let empty = NetworkPeaks(
        peakDownBytesPerSecond: 0,
        peakUpBytesPerSecond: 0,
        peakAt: nil,
        totalDownBytes: 0,
        totalUpBytes: 0,
        sampledSeconds: 0,
        hasSamples: false
    )
}

extension NetworkPeaks {
    /// The caption under the "24-Hour Peak" card.
    var footnote: String {
        guard hasSamples else { return "No History Yet" }
        return "Sampled \(HogFormat.duration(sampledSeconds))"
    }

    /// What the peak means and, when known, when it was reached.
    var help: String {
        guard let at = peakAt else {
            return "The fastest sustained download or upload seen in the last 24 hours."
        }
        let when = DateFormatter.localizedString(from: at, dateStyle: .none, timeStyle: .short)
        return "The fastest sustained rate in the last 24 hours, reached at \(when)."
    }
}

/// Samples interface counters on its own timer and keeps the peaks in the
/// history database.
///
/// It runs for the life of the app rather than only while the Network tab is
/// open: a peak that only existed while you were looking at the tab would be
/// no peak at all.  `getifaddrs` costs microseconds, and the write is one row
/// per sample, pruned with everything else.
@MainActor
final class BandwidthStore: ObservableObject {
    @Published private(set) var reading: BandwidthReading = .pending
    @Published private(set) var peaks: NetworkPeaks = .empty
    @Published private(set) var lastError: String?

    /// How often counters are read and recorded.
    static let sampleInterval: TimeInterval = 5

    private let history: HistoryStore
    private let queue = DispatchQueue(label: "hoghunter.bandwidth", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var tracker = BandwidthTracker()
    private var lastRecordedAt: Date = .distantPast

    init(history: HistoryStore) {
        self.history = history
    }

    deinit {
        timer?.cancel()
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.sampleInterval)
        timer.setEventHandler { [weak self] in
            self?.readCountersOffMain()
        }
        self.timer = timer
        timer.resume()
        refreshPeaks()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Re-reads the peaks, e.g. when the Network tab appears.
    func refreshPeaks(lookback: TimeInterval = 24 * 60 * 60) {
        let history = self.history
        queue.async { [weak self] in
            let peaks = history.networkPeaks(lookback: lookback)
            Task { @MainActor [weak self] in
                self?.peaks = peaks
            }
        }
    }

    /// Runs on the timer queue: `getifaddrs` touches the kernel and has no
    /// business being on the main actor.  Everything else hops back.
    private nonisolated func readCountersOffMain() {
        let counters = InterfaceTraffic.counters()
        let now = Date()
        Task { @MainActor [weak self] in
            self?.ingest(counters, at: now)
        }
    }

    private func ingest(_ counters: InterfaceCounters?, at now: Date) {
        guard let counters else {
            lastError = "Could not read the network interface counters."
            return
        }
        reading = tracker.ingest(counters, at: now)
        lastError = nil
        guard now.timeIntervalSince(lastRecordedAt) >= Self.sampleInterval else { return }
        lastRecordedAt = now
        let history = self.history
        queue.async { [weak self] in
            history.recordNetwork(bytesIn: counters.received, bytesOut: counters.sent, at: now)
            // Peaks only move when a sample lands, so recomputing them on the
            // sample cadence keeps the query off the 3 s app tick.
            let peaks = history.networkPeaks(lookback: 24 * 60 * 60)
            Task { @MainActor [weak self] in
                self?.peaks = peaks
            }
        }
    }
}
