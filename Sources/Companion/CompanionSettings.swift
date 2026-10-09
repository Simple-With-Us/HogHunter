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
    }

    static func validate(_ request: CompanionSettingsUpdateRequest) -> Result<Validated, CompanionSettingsRejection> {
        var validated = Validated(testWebhook: request.testWebhook == true)

        if let interval = request.refreshInterval {
            guard CompanionSettingsLimits.refreshIntervals.contains(interval) else {
                return .failure(.init("The refresh interval must be 2, 3, 5, 10 or 15 seconds."))
            }
            validated.refreshInterval = interval
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
        return .success(validated)
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
        return .success(trimmed)
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
        notificationsDenied: Bool
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
            webhookHost: configured ? URL(string: trimmed)?.host : nil,
            webhookStatus: status,
            notificationsDenied: notificationsDenied
        )
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
