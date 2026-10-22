import Foundation

/// Checks a settings change from the phone before the Mac applies any of it.
///
/// The phone's pickers offer only values the Mac accepts, but the router
/// receives bytes, not pickers.  `defaultsChanged` accepts any refresh
/// interval of one second or more, so nothing downstream would catch a bad
/// value; this is the only gate.  A change is applied whole or not at all:
/// one bad field rejects the request.
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
            guard CompanionSettingsLimits.refreshIntervals.contains(interval) else {
                return .failure(.init("The refresh interval must be 2, 3, 5, 10 or 15 seconds."))
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
            guard CompanionSettingsLimits.backgroundRefreshIntervals.contains(interval) else {
                return .failure(.init("The background refresh interval must be 5, 10, 15 or 30 seconds."))
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
        sortAscending: Bool = false
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
            sortAscending: sortAscending
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

extension CpuScale {
    /// The scale a phone's name for it means.  The phone sends the stored
    /// names ("Per Core", "Share of Machine"); the label it shows for the
    /// second is "Per Machine", so both are understood.
    static func fromPhone(_ name: String) -> CpuScale? {
        let lower = name.lowercased()
        if lower.contains("machine") || lower.contains("share") { return .machineShare }
        if lower.contains("core") { return .perCore }
        return nil
    }
}

extension HogSort {
    /// The sort a phone's name for it means.  The Mac's own names are "CPU"
    /// and "Memory"; the phone's picker offers them, and a hand-built
    /// request can spell them any way it likes.
    static func fromPhone(_ name: String) -> HogSort? {
        let lower = name.lowercased()
        if lower.contains("memory") || lower.contains("ram") { return .memory }
        if lower.contains("cpu") { return .cpu }
        return nil
    }
}
