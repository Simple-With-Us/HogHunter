import Foundation
import UserNotifications

/// The decision half of alerting, with no notification machinery in it.
///
/// Feed it one `step` per candidate per tick.  It answers the only question
/// that matters: should this row fire right now?  A row must stay above the
/// threshold for `sustained` before it fires, dropping below resets that
/// clock, and after a firing the same row is quiet for `cooldown`.
struct AlertPolicy {
    /// How long a row must stay above the threshold before it fires.
    var sustained: TimeInterval
    /// How long a row stays quiet after firing.
    var cooldown: TimeInterval

    /// When each row first went above the threshold and stayed there.
    private var firstExceeded: [String: Date] = [:]
    /// When each row last fired.  Kept across a drop below the threshold, and
    /// across a row leaving the candidate set, so a row that flaps cannot
    /// notify twice in one cooldown.
    private var lastFired: [String: Date] = [:]

    init(sustained: TimeInterval = 5 * 60, cooldown: TimeInterval = 30 * 60) {
        self.sustained = sustained
        self.cooldown = cooldown
    }

    /// Recompute from the current project on every pass; missing keys must not
    /// retain a previous project's policy value.
    mutating func applyCooldown(minutes: Double?) {
        if let minutes, minutes.isFinite, minutes > 0 {
            cooldown = minutes * 60
        } else {
            cooldown = 30 * 60
        }
    }

    /// True exactly on the tick where `id` earns a notification.
    mutating func step(id: String, above: Bool, now: Date) -> Bool {
        guard above else {
            firstExceeded[id] = nil
            return false
        }
        let start = firstExceeded[id] ?? now
        firstExceeded[id] = start
        guard now.timeIntervalSince(start) >= sustained else { return false }
        if let last = lastFired[id], now.timeIntervalSince(last) < cooldown { return false }
        lastFired[id] = now
        return true
    }

    /// How long `id` has been above the threshold, or 0 when it is not.
    func timeAboveThreshold(id: String, now: Date) -> TimeInterval {
        guard let start = firstExceeded[id] else { return 0 }
        return max(0, now.timeIntervalSince(start))
    }

    /// Every id the policy is still tracking.  Only the tests read this; it
    /// exists so the memory bound can be pinned.
    var trackedIds: Set<String> {
        Set(firstExceeded.keys).union(lastFired.keys)
    }

    /// Forgets rows the caller no longer considers, so a long session does not
    /// grow a dictionary entry per process it ever saw.  The sustained clock is
    /// dropped with the row -- restarting it only ever delays a notification --
    /// but `lastFired` expires by age instead, so a row that leaves the
    /// candidate set and comes back cannot notify twice inside one cooldown.
    mutating func forgetAll(except live: Set<String>, now: Date) {
        firstExceeded = firstExceeded.filter { live.contains($0.key) }
        lastFired = lastFired.filter { live.contains($0.key) || now.timeIntervalSince($0.value) < cooldown }
    }

    /// Drops every entry, the way it looked when alerts were first switched on.
    /// Called when alerting is turned off, so re-enabling starts from a clean
    /// slate instead of letting a row that was in cooldown fire immediately
    /// or letting a row that was 4 minutes into a 5-minute sustained window
    /// fire after only one more minute.
    mutating func reset() {
        firstExceeded.removeAll()
        lastFired.removeAll()
    }
}

/// Turns sustained CPU into one notification, and nothing else.
@MainActor
final class Alerts: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    /// One row the policy is allowed to consider.  Deliberately not a `HogRow`:
    /// the candidate set is the whole above-threshold list, not the truncated,
    /// user-sorted set of rows the panel happens to be drawing.
    struct Candidate {
        var id: String
        var name: String
        /// Per-core scale, the same scale as `alertThresholdPercent`.
        var cpuPercent: Double
    }

    /// True once the user has said no.  Settings shows it next to the toggle.
    @Published private(set) var authorizationDenied = false
    /// The last thing the notification centre refused to do, if anything.
    @Published private(set) var lastError: String?
    /// Optional webhook URL for remote sustained-hog notification dispatch (Slack, Discord, Pushover).
    @Published var webhookURL: String = ""
    /// Result or status of the most recent webhook dispatch.
    @Published private(set) var lastWebhookStatus: String?

    private var policy = AlertPolicy()
    private var didRequestAuthorization = false

    /// Drops every entry the policy is tracking.  Called when alerts are
    /// turned off, so re-enabling starts from a clean slate and a row that
    /// was in cooldown (or most of the way through a sustained window) does
    /// not finish where it left off.
    func resetPolicy() {
        policy.reset()
    }

    /// Nil when there is no bundle to notify from, which is the case in unit
    /// tests and in any unbundled run.  Asking for the centre in that state
    /// traps, so it is never asked.  The delegate is set here, behind the same
    /// guard: without one, macOS drops any notification that arrives while Hog
    /// Hunter is the active app, and the cooldown would still be spent.
    private lazy var center: UNUserNotificationCenter? = {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }()

    /// Shows the banner even when Settings or the panel is key.  Touches no
    /// instance state, so it is safe to leave off the main actor -- which it
    /// must be, because the protocol itself is not main-actor isolated.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// Called when the setting is switched on, and once at launch when it is
    /// already on, so the decision is settled long before a row can fire.
    func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
        guard let center else {
            authorizationDenied = true
            completion?(false)
            return
        }
        didRequestAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.authorizationDenied = !granted
                if let error { self.lastError = error.localizedDescription }
                completion?(granted)
            }
        }
    }

    /// One pass over the candidates the store handed in.  Everything at or
    /// above the threshold is here, whatever the panel is showing, so Sort and
    /// the 25-row display limit cannot silently switch alerting off.  The
    /// store pre-filters `candidates` to those already at or above
    /// `threshold`, so the `above == false` path below is normally dead code
    /// here -- it exists to serve a caller that passes unfiltered rows, for
    /// which it correctly resets the sustained clock instead of notifying.
    func evaluate(
        candidates: [Candidate],
        threshold: Double,
        sustained: TimeInterval,
        now: Date = Date()
    ) {
        policy.sustained = max(1, sustained)
        // Infisical-overridable cooldown (minutes); the 30-minute built-in
        // stands when Infisical is not configured.
        policy.applyCooldown(minutes: InfisicalStore.shared.double(for: InfisicalKey.alertCooldownMinutes))
        var live: Set<String> = []
        live.reserveCapacity(candidates.count)
        for candidate in candidates {
            live.insert(candidate.id)
            let above = candidate.cpuPercent >= threshold
            let elapsed = above ? policy.timeAboveThreshold(id: candidate.id, now: now) : 0
            guard policy.step(id: candidate.id, above: above, now: now) else { continue }
            notify(candidate: candidate, seconds: max(elapsed, policy.sustained))
        }
        policy.forgetAll(except: live, now: now)
    }

    /// "Chrome has used 412% of one core for 5 minutes."  The threshold is set
    /// on the per-core scale, so the notification names that scale rather than
    /// converting to whatever the rows are showing.
    static func message(name: String, cpuPercent: Double, seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        let unit = minutes == 1 ? "minute" : "minutes"
        return "\(name) has used \(HogFormat.cpu(cpuPercent)) of one core for \(minutes) \(unit)."
    }

    private func notify(candidate: Candidate, seconds: TimeInterval) {
        if let center {
            if !didRequestAuthorization { requestAuthorization() }
            let content = UNMutableNotificationContent()
            content.title = "Hog Hunter"
            content.body = Self.message(name: candidate.name, cpuPercent: candidate.cpuPercent, seconds: seconds)
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "hog-\(candidate.id)-\(Int(Date().timeIntervalSince1970))",
                content: content,
                trigger: nil
            )
            center.add(request) { error in
                guard let error else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.lastError = error.localizedDescription
                }
            }
        }

        let trimmedWebhook = webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedWebhook.isEmpty {
            sendWebhook(candidate: candidate, seconds: seconds, webhookURL: trimmedWebhook, isTest: false)
        }
    }

    /// Sends a test webhook notification to verify endpoint connectivity.
    func sendTestWebhook(to urlString: String) {
        let testCandidate = Candidate(id: "test", name: "Test Process (Hog Hunter)", cpuPercent: 350.0)
        sendWebhook(candidate: testCandidate, seconds: 300, webhookURL: urlString, isTest: true)
    }

    private func sendWebhook(candidate: Candidate, seconds: TimeInterval, webhookURL: String, isTest: Bool) {
        let trimmed = webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" else {
            self.lastWebhookStatus = "Invalid webhook URL"
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let alertMsg = isTest
            ? "Test alert from Hog Hunter: Sustained hog webhook dispatch is functioning properly."
            : Self.message(name: candidate.name, cpuPercent: candidate.cpuPercent, seconds: seconds)

        let payload: [String: Any] = [
            "text": alertMsg,
            "content": alertMsg,
            "message": alertMsg,
            "title": "Hog Hunter Alert",
            "candidate": candidate.name,
            "cpu_percent": candidate.cpuPercent,
            "duration_seconds": seconds,
            "is_test": isTest,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            self.lastWebhookStatus = "Failed to encode JSON: \(error.localizedDescription)"
            return
        }

        self.lastWebhookStatus = "Sending..."

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error = error {
                    self.lastWebhookStatus = "Failed: \(error.localizedDescription)"
                } else if let http = response as? HTTPURLResponse {
                    if (200...299).contains(http.statusCode) {
                        let formatter = DateFormatter()
                        formatter.timeStyle = .medium
                        self.lastWebhookStatus = "Delivered (\(http.statusCode)) at \(formatter.string(from: Date()))"
                    } else {
                        self.lastWebhookStatus = "HTTP Error \(http.statusCode)"
                    }
                }
            }
        }.resume()
    }
}

/// So `Alerts.AlertPolicy` resolves as well as the top-level name.
extension Alerts {
    typealias AlertPolicy = HogHunter.AlertPolicy
}
