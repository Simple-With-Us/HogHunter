import Foundation

/// Freshness and throttle maths for the iPhone dashboard. Foundation only,
/// so the values the views show can be reasoned about without SwiftUI.
enum CompanionFreshness {
    /// Past this snapshot age the reading is stale, even if polls succeed.
    static let staleAfter: TimeInterval = 15
    /// Past this since the last successful poll the phone is reconnecting.
    /// Matches the 30s grace the poll loop already used for its status line.
    static let reconnectingAfter: TimeInterval = 30

    enum State: Equatable { case live, stale, reconnecting }

    /// `throttledUntil` is the poll throttle deadline when a 429 holds the
    /// loop, else nil.  A 429 is an answer, so while it holds the link is
    /// alive by definition: the state caps at stale and the countdown
    /// beside it explains the wait, instead of claiming Reconnecting.
    static func state(sampledAt: Date?, lastSuccessfulRefresh: Date, now: Date, throttledUntil: Date? = nil) -> State {
        if let throttledUntil, now < throttledUntil {
            guard let sampledAt else { return .stale }
            return now.timeIntervalSince(sampledAt) > staleAfter ? .stale : .live
        }
        guard sampledAt != nil else { return .reconnecting }
        if now.timeIntervalSince(lastSuccessfulRefresh) > reconnectingAfter { return .reconnecting }
        if let sampledAt, now.timeIntervalSince(sampledAt) > staleAfter { return .stale }
        return .live
    }

    /// Whole seconds left until `until`, never negative, rounded up so the
    /// button does not re-enable a second early.
    static func remainingSeconds(until: Date?, now: Date) -> Int {
        guard let until else { return 0 }
        return max(0, Int(ceil(until.timeIntervalSince(now))))
    }

    static func ageText(sampledAt: Date?, now: Date) -> String {
        guard let sampledAt else { return "No reading yet" }
        let age = max(0, now.timeIntervalSince(sampledAt))
        if age < 5 { return "Updated just now" }
        if age < 60 { return "Updated \(Int(age)) seconds ago" }
        if age < 3600 { return "Updated \(Int(age / 60)) minutes ago" }
        return "Updated \(Int(age / 3600)) hours ago"
    }

    static func freshnessText(sampledAt: Date?, lastSuccessfulRefresh: Date, now: Date, throttledUntil: Date? = nil) -> String {
        switch state(sampledAt: sampledAt, lastSuccessfulRefresh: lastSuccessfulRefresh, now: now, throttledUntil: throttledUntil) {
        case .live: return ageText(sampledAt: sampledAt, now: now)
        case .stale: return "\(ageText(sampledAt: sampledAt, now: now)) — may be out of date"
        case .reconnecting: return "Reconnecting…\u{00A0} \(ageText(sampledAt: sampledAt, now: now))"
        }
    }

    static func countdownText(remainingSeconds: Int) -> String? {
        guard remainingSeconds > 0 else { return nil }
        return remainingSeconds == 1 ? "Try again in 1 second" : "Try again in \(remainingSeconds) seconds"
    }
}
