import Foundation

/// What a `hoghunter://` link is allowed to do.
///
/// `clean` asks the phone to show the confirmation.  It does not start a
/// clean.  `triggerRemoteClean` runs only after the person taps Run Safe
/// Clean, and the Mac still applies its own opt-in.
enum CompanionDeepLink: Equatable {
    case openApp
    case confirmClean
    case ignore

    static func classify(_ url: URL) -> CompanionDeepLink {
        guard url.scheme?.lowercased() == "hoghunter" else { return .ignore }
        switch url.host?.lowercased() {
        case "clean":
            return .confirmClean
        case "open":
            return .openApp
        default:
            return .ignore
        }
    }

    /// True only for the confirmation request.  No link is permission to call
    /// `triggerRemoteClean`.
    var requestsCleanConfirmation: Bool { self == .confirmClean }
}

/// The Clean link may open a confirmation.  It may not start a clean, and it
/// may not offer one unless the Mac has already opted in.
enum CleanLinkPolicy {
    static let cleanOffNote = "Cleaning from iPhone is off.  Turn on Allow iPhone to Run Disk Cleaner in Hog Hunter Settings > iPhone on your Mac."

    /// Same gate as the in-app Clean button.  Nil and false both stay off.
    static func mayOfferCleanConfirmation(remoteCleanAllowed: Bool?) -> Bool {
        remoteCleanAllowed == true
    }

    /// Persist and reload only when the shared container exists and the
    /// snapshot encoded.  A missing App Group makes
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` nil.
    /// `UserDefaults(suiteName:)` is not that signal.
    static func shouldReloadWidget(
        appGroupContainerAvailable: Bool,
        snapshotEncoded: Bool,
        cleanKeysChanged: Bool,
        reloadDue: Bool
    ) -> Bool {
        guard appGroupContainerAvailable, snapshotEncoded else { return false }
        return cleanKeysChanged || reloadDue
    }
}

/// Whether a pending Clean confirmation is still the link that just arrived.
enum CleanRequest {
    /// Long enough for a cold start to reach the dashboard, short enough that
    /// a link is not replayed once the Mac reconnects much later.
    static let lifetime: TimeInterval = 30

    static func isFresh(pending: Bool, issuedAt: Date?, now: Date, lifetime: TimeInterval = CleanRequest.lifetime) -> Bool {
        guard pending, let issuedAt else { return false }
        return now.timeIntervalSince(issuedAt) < lifetime
    }
}
