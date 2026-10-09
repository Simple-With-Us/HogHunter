import Foundation

/// Slows down anyone who keeps presenting a wrong pairing code or token.
///
/// The shared pairing code is about 40 bits, so without a limit it can be
/// guessed.  Each client address gets a few free misses, then a lockout that
/// doubles per miss up to 15 minutes.  A client that stays quiet is forgiven,
/// and a good request clears its slate.  A separate global cap covers an
/// outside attacker who rotates addresses.  Not thread safe: the server uses
/// it only on its own queue.
struct CompanionAuthThrottle {
    struct Policy: Equatable {
        /// Misses allowed before the first lockout.
        var freeFailures = 5
        /// Length of the first lockout, in seconds.  Each further miss doubles it.
        var baseDelay: TimeInterval = 2
        var maxDelay: TimeInterval = 15 * 60
        /// A client that has not missed for this long starts over.
        var forgetAfter: TimeInterval = 15 * 60
        /// Most client addresses remembered.  The oldest are dropped first.
        var capacity = 256
        /// Misses across all clients, within `globalWindow`, that lock everyone.
        var globalLimit = 120
        var globalWindow: TimeInterval = 60
    }

    private struct Entry {
        var failures: Int
        var lastFailure: Date
        var lockedUntil: Date
    }

    var policy = Policy()
    private var entries: [String: Entry] = [:]
    private var recentFailures: [Date] = []

    /// Seconds the client must wait, rounded up, or nil if it may try now.
    ///
    /// The global cap is for addresses outside the local network and
    /// Tailscale (`appliesGlobal`), where a guesser can rotate addresses and
    /// where anyone on the internet can reach a forwarded port.  It does not
    /// lock the phone on the home Wi-Fi out because strangers are guessing.
    func retryAfter(for peer: String, now: Date, appliesGlobal: Bool = true) -> Int? {
        var wait: TimeInterval = 0
        if let entry = entries[peer], now.timeIntervalSince(entry.lastFailure) < policy.forgetAfter {
            wait = max(wait, entry.lockedUntil.timeIntervalSince(now))
        }
        if appliesGlobal {
            let window = recentFailures.filter { now.timeIntervalSince($0) < policy.globalWindow }
            if window.count >= policy.globalLimit, let oldest = window.min() {
                wait = max(wait, policy.globalWindow - now.timeIntervalSince(oldest))
            }
        }
        return wait > 0 ? Int(wait.rounded(.up)) : nil
    }

    /// `countsTowardGlobal` is false for trusted-network clients, so their
    /// misses never feed the cap that locks out the outside world.
    mutating func recordFailure(peer: String, now: Date, countsTowardGlobal: Bool = true) {
        var entry = entries[peer] ?? Entry(failures: 0, lastFailure: now, lockedUntil: .distantPast)
        if now.timeIntervalSince(entry.lastFailure) >= policy.forgetAfter {
            entry.failures = 0
        }
        entry.failures += 1
        entry.lastFailure = now
        if entry.failures >= policy.freeFailures {
            let steps = min(entry.failures - policy.freeFailures, 30)
            let delay = min(policy.maxDelay, policy.baseDelay * pow(2, Double(steps)))
            entry.lockedUntil = now.addingTimeInterval(delay)
        }
        entries[peer] = entry

        if countsTowardGlobal {
            recentFailures.append(now)
        }
        recentFailures.removeAll { now.timeIntervalSince($0) >= policy.globalWindow }
        evictIfNeeded(now: now)
    }

    mutating func recordSuccess(peer: String) {
        entries.removeValue(forKey: peer)
    }

    var trackedPeerCount: Int { entries.count }

    private mutating func evictIfNeeded(now: Date) {
        guard entries.count > policy.capacity else { return }
        entries = entries.filter { now.timeIntervalSince($0.value.lastFailure) < policy.forgetAfter }
        while entries.count > policy.capacity,
              let oldest = entries.min(by: { $0.value.lastFailure < $1.value.lastFailure })?.0 {
            entries.removeValue(forKey: oldest)
        }
    }
}
