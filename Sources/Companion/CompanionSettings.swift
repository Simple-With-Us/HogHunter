import Foundation

/// Checks a settings change from the phone before the Mac applies any of it.
///
/// The phone's pickers offer the Mac's own choices plus whatever the Mac is
/// already using, but the router receives bytes, not pickers.  `defaultsChanged`
/// accepts any refresh interval of one second or more, so nothing downstream
/// would catch a bad value; this is the only gate.  A change is applied whole
/// or not at all: one bad field rejects the request.
enum CompanionSettingsValidator {
    /// A change that passed every check, in the shape the store applies.
    struct Validated: Equatable {
        var refreshInterval: Double?
        var alertsEnabled: Bool?
        var alertThresholdPercent: Double?
        var alertSustainedMinutes: Int?
        /// Nil leaves the webhook alone.  Empty clears it.
        var webhookURL: String?
        var testWebhook: Bool
        /// The Mac's appearance: System, Light or Dark.
        var appearance: AppearanceChoice?
        /// The refresh cadence the Mac uses while its panel is closed.
        var backgroundRefreshInterval: Double?
        /// What the Mac's menu bar shows.
        var menuBarLabelMode: MenuBarLabelMode?
    }

    static func validate(_ request: CompanionSettingsUpdateRequest) -> Result<Validated, CompanionSettingsRejection> {
        var validated = Validated(testWebhook: request.testWebhook == true)

        if let interval = request.refreshInterval {
            guard Self.isAcceptedInterval(interval) else {
                return .failure(.init("The refresh interval must be at least one second."))
            }
            validated.refreshInterval = interval
        }
        if request.testWebhook == true, request.webhookURL != nil {
            return .failure(.init("Save the webhook first, then send a test."))
        }
        if let enabled = request.alertsEnabled {
            validated.alertsEnabled = enabled
        }
        if let threshold = request.alertThresholdPercent {
            let range = CompanionSettingsLimits.alertThresholdRange
            let step = CompanionSettingsLimits.alertThresholdStep
            let steps = (threshold - range.lowerBound) / step
            guard threshold.isFinite, range.contains(threshold), steps == steps.rounded() else {
                return .failure(.init("The CPU threshold must be between \(Int(range.lowerBound)) and \(Int(range.upperBound)) percent, in steps of \(Int(step))."))
            }
            validated.alertThresholdPercent = threshold
        }
        if let minutes = request.alertSustainedMinutes {
            let range = CompanionSettingsLimits.alertSustainedMinutesRange
            guard range.contains(minutes) else {
                return .failure(.init("The sustained time must be between \(range.lowerBound) and \(range.upperBound) minutes."))
            }
            validated.alertSustainedMinutes = minutes
        }
        if let raw = request.webhookURL {
            switch normalizedWebhook(raw) {
            case .success(let url): validated.webhookURL = url
            case .failure(let rejection): return .failure(rejection)
            }
        }
        if let raw = request.appearance {
            guard let choice = Self.appearance(from: raw) else {
                return .failure(.init("The appearance must be System, Light or Dark."))
            }
            validated.appearance = choice
        }
        if let interval = request.backgroundRefreshInterval {
            guard Self.isAcceptedInterval(interval) else {
                return .failure(.init("The background refresh interval must be at least one second."))
            }
            validated.backgroundRefreshInterval = interval
        }
        if let raw = request.menuBarLabelMode {
            guard let mode = Self.menuBarLabelMode(from: raw) else {
                return .failure(.init("The menu bar must show Machine CPU, Top Hog or Live Sparkline."))
            }
            validated.menuBarLabelMode = mode
        }
        return .success(validated)
    }

    /// The Mac's own rule for both refresh intervals.
    ///
    /// `defaultsChanged` applies any interval of a second or more when the
    /// settings are loaded, and the Mac's own Settings window offers the
    /// small set of choices in `CompanionSettingsLimits`.  The validator
    /// uses the load rule rather than the small set, so the Mac can never
    /// refuse a value it is already holding, and the phone is never offered
    /// a choice the Mac would turn down.
    static func isAcceptedInterval(_ interval: Double) -> Bool {
        interval.isFinite && interval >= 1
    }

    /// The Mac's appearance, from the name the phone sent.  The phone's
    /// picker offers the Mac's own names, but the router receives bytes, and
    /// a hand-built request can spell them any way it likes.
    static func appearance(from raw: String) -> AppearanceChoice? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppearanceChoice.allCases.first { $0.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// The Mac's menu bar label mode, from the name the phone sent.
    static func menuBarLabelMode(from raw: String) -> MenuBarLabelMode? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return MenuBarLabelMode.allCases.first { $0.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// Empty clears the webhook.  Anything else must be an https URL with a
    /// host.  The URL is a credential and crosses an unencrypted link, so the
    /// phone may not set a plain http one; the alert payload names processes.
    static func normalizedWebhook(_ raw: String) -> Result<String, CompanionSettingsRejection> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .success("") }
        guard trimmed.count <= CompanionSettingsLimits.webhookMaxLength,
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else {
            return .failure(.init("The webhook must be an https address.\u{00A0} Set an http one on the Mac."))
        }
        // The alert sender compares the scheme as typed, so "HTTPS://" would
        // pass here and then fail there.  Store it in the form it expects.
        return .success("https" + trimmed.dropFirst("https".count))
    }
}

struct CompanionSettingsRejection: Error, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
}

extension CompanionSettingsUpdateResponse {
    static func rejected(_ message: String) -> CompanionSettingsUpdateResponse {
        CompanionSettingsUpdateResponse(status: "rejected", message: nil, error: message)
    }
}

extension CompanionSnapshotBuilder {
    /// The phone's view of the settings it may change.  The webhook URL is
    /// reduced to its host, and any delivery status that quotes the URL has
    /// the URL taken out of it.
    static func settingsSummary(
        refreshInterval: Double,
        alertsEnabled: Bool,
        alertThresholdPercent: Double,
        alertSustainedMinutes: Int,
        webhookURL: String,
        webhookStatus: String?,
        notificationsDenied: Bool,
        appearance: AppearanceChoice = .system,
        backgroundRefreshInterval: Double = 10,
        menuBarLabelMode: MenuBarLabelMode = .machinePercent,
        sort: HogSort = .cpu,
        sortAscending: Bool = false,
        resolvedAppearance: String = "Light"
    ) -> CompanionSettingsSummary {
        let trimmed = webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let configured = !trimmed.isEmpty
        var status = webhookStatus
        if configured, let text = status {
            status = text.replacingOccurrences(of: trimmed, with: "the webhook")
        }
        return CompanionSettingsSummary(
            refreshInterval: refreshInterval,
            alertsEnabled: alertsEnabled,
            alertThresholdPercent: alertThresholdPercent,
            alertSustainedMinutes: alertSustainedMinutes,
            webhookConfigured: configured,
            webhookHost: configured ? URL(string: trimmed)?.host.map(maskedWebhookHost) : nil,
            webhookStatus: status,
            notificationsDenied: notificationsDenied,
            appearance: appearance.rawValue,
            backgroundRefreshInterval: backgroundRefreshInterval,
            menuBarLabelMode: menuBarLabelMode.rawValue,
            sort: sort.rawValue,
            sortAscending: sortAscending,
            resolvedAppearance: resolvedAppearance
        )
    }

    /// Enough of the host to recognise the service, not enough to be a
    /// credential.  Some services put the secret endpoint id in a subdomain
    /// ("abc123.m.pipedream.net"), and the snapshot is readable with the shared
    /// code, so only the last two labels are shown: "...pipedream.net".
    static func maskedWebhookHost(_ host: String) -> String {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return host }
        return "…" + labels.suffix(2).joined(separator: ".")
    }

    /// Throughput and 24-hour peak, formatted with the same words the Network
    /// tab on the Mac uses.
    static func bandwidth(reading: BandwidthReading, peaks: NetworkPeaks, error: String?) -> CompanionBandwidth {
        CompanionBandwidth(
            isMeasured: reading.isMeasured,
            downBytesPerSecond: reading.downBytesPerSecond,
            upBytesPerSecond: reading.upBytesPerSecond,
            downText: HogFormat.rate(reading.downBytesPerSecond),
            upText: HogFormat.rate(reading.upBytesPerSecond),
            nowFootnote: reading.footnote,
            peakDownBytesPerSecond: peaks.peakDownBytesPerSecond,
            peakUpBytesPerSecond: peaks.peakUpBytesPerSecond,
            peakDownText: HogFormat.rate(peaks.peakDownBytesPerSecond),
            peakUpText: HogFormat.rate(peaks.peakUpBytesPerSecond),
            peakFootnote: peaks.footnote,
            peakHelp: peaks.help,
            error: error
        )
    }
}

/// A name that arrived over the wire, folded into the form a whole-token
/// comparison can use:  trimmed, lower case, one space between words.
///
/// The routes take bytes, not pickers, so a name is checked against the
/// exact set the Mac accepts.  A name that merely contains a known word is
/// not that word:  "program" is not "Memory", and "cpu usage" is not "CPU".
enum CompanionNames {
    static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

extension CpuScale {
    /// The scale a phone's name for it means.  The phone sends the stored
    /// names ("Per Core", "Share of Machine"); the label it shows for the
    /// second is "Per Machine", so both are understood.
    static func fromPhone(_ name: String) -> CpuScale? {
        switch CompanionNames.normalized(name) {
        case "per core", "core": return .perCore
        case "share of machine", "per machine", "machine share", "machine", "share": return .machineShare
        default: return nil
        }
    }
}

extension HogSort {
    /// The sort a phone's name for it means.  The Mac's own names are "CPU"
    /// and "Memory", and the phone's picker sends one of them, so only those
    /// two names are understood.
    static func fromPhone(_ name: String) -> HogSort? {
        switch CompanionNames.normalized(name) {
        case "memory": return .memory
        case "cpu": return .cpu
        default: return nil
        }
    }
}

/// The Mac's view state:  the window, grouping, CPU scale and sort its panel
/// is showing.
///
/// The published properties live on the main actor and the phone's view route
/// answers on the server queue, so the state is carried here and resolved in
/// one place.  A field the request leaves out keeps the value the Mac has,
/// so the reply describes the state the Mac is really in.
struct CompanionViewState: Equatable {
    var window: TimeWindow = .now
    var grouping: HogGrouping = .apps
    var cpuScale: CpuScale = .perCore
    var sort: HogSort = .cpu
    var sortAscending: Bool = false

    /// The state the Mac is in after the request.
    func resolving(after request: CompanionViewUpdateRequest) -> CompanionViewState {
        var next = self
        if let raw = request.window, let value = Self.window(from: raw) { next.window = value }
        if let raw = request.grouping, let value = Self.grouping(from: raw) { next.grouping = value }
        if let raw = request.cpuScale, let value = CpuScale.fromPhone(raw) { next.cpuScale = value }
        if let raw = request.sort, let value = HogSort.fromPhone(raw) { next.sort = value }
        if let ascending = request.sortAscending {
            next.sortAscending = ascending
        } else if next.sort != sort {
            // The Mac puts the list back the right way round when the sort
            // changes, so the reply must not claim the old direction.
            next.sortAscending = false
        }
        return next
    }

    /// The window a phone's name for it means.
    static func window(from raw: String) -> TimeWindow? {
        switch CompanionNames.normalized(raw) {
        case "now": return .now
        case "1h", "1 hour", "past hour", "past 1 hour": return .hour
        case "24h", "24 hours", "past 24 hours", "day": return .day
        default: return nil
        }
    }

    /// The grouping a phone's name for it means.
    static func grouping(from raw: String) -> HogGrouping? {
        switch CompanionNames.normalized(raw) {
        case "apps": return .apps
        case "processes": return .processes
        default: return nil
        }
    }
}
