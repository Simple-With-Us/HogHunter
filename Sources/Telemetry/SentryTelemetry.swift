import Foundation
import Sentry

/// Sentry crash and transaction telemetry for the `hoghunter` project.
///
/// Fleet pattern (BotFleet / ContactLogo Cocoa): the DSN comes only from
/// Info.plist (`SentryDSN`, expanded from the `SENTRY_DSN` build setting).
/// An empty, missing, or unexpanded DSN is a silent no-op, so local and CI
/// builds without the secret report nothing.  Never hardcode a DSN here.
///
/// Shared by the macOS menubar target and the iOS companion target.  The
/// widget extension is deliberately not instrumented.  Session Replay is
/// off: the panel lists running processes and the phone can name paths
/// through the snapshot.
enum SentryTelemetry {
    /// Info.plist key holding the DSN.  Both app targets expand it from `$(SENTRY_DSN)`.
    static let dsnInfoKey = "SentryDSN"
    /// Single Sentry environment tag; Hog Hunter ships one deployment.
    static let environment = "production"
    /// Fraction of transactions sampled for tracing.
    static let tracesSampleRate: Float = 0.2
    /// Fraction of sessions sampled for continuous profiling.
    static let profilesSessionSampleRate: Float = 0.1
    /// App-hang threshold, seconds.  Hog Hunter samples on a 3-second cadence,
    /// so a hang longer than one interval is worth reporting.
    static let appHangTimeout: TimeInterval = 2
    /// Query names stripped from any captured URL before it leaves the device.
    static let redactedQueryNames = ["token", "key", "secret", "auth", "password"]
    /// Launch flags that must keep Sentry inert (CI smoke and screenshot hooks).
    static let inertLaunchFlags = ["-HogHunterUISmoke", "-HogHunterScreenshot"]

    /// Plain configuration, resolved without touching the SDK.  Tests assert
    /// on this; `start()` maps it onto `SentryOptions`.
    struct Configuration: Equatable {
        var dsn: String
        var release: String
        var environment: String
        var tracesSampleRate: Float
        var profilesSessionSampleRate: Float
    }

    /// Release in `CFBundleShortVersionString+build` form, e.g. `1.0.6+202610060122`.
    static func releaseName(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = bundle.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "0"
        return "\(version)+\(build)"
    }

    /// False for the CI smoke and screenshot hooks so those launches never send.
    static func shouldStart(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        !arguments.contains(where: { inertLaunchFlags.contains($0) })
    }

    /// Returns nil when no usable DSN is configured, which makes `start()` a no-op.
    static func configuration(bundle: Bundle = .main) -> Configuration? {
        guard let raw = bundle.object(forInfoDictionaryKey: dsnInfoKey) as? String else { return nil }
        let dsn = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dsn.isEmpty, dsn.hasPrefix("https://") else { return nil }
        return Configuration(
            dsn: dsn,
            release: releaseName(bundle: bundle),
            environment: environment,
            tracesSampleRate: tracesSampleRate,
            profilesSessionSampleRate: profilesSessionSampleRate
        )
    }

    /// Redact pairing tokens and other secrets from a captured request URL.
    static func redactSensitiveURL(_ url: String) -> String {
        var sanitized = url
        for param in redactedQueryNames {
            sanitized = sanitized.replacingOccurrences(
                of: "([?&]\(param)=)[^&#\\s]+",
                with: "$1[REDACTED]",
                options: .regularExpression
            )
        }
        return sanitized
    }

    /// Starts Sentry when a DSN is configured; silently does nothing otherwise.
    /// Call once, early, from the app entry point.
    static func start(bundle: Bundle = .main) {
        guard shouldStart() else { return }
        guard let config = configuration(bundle: bundle) else { return }
        SentrySDK.start { options in
            options.dsn = config.dsn
            options.releaseName = config.release
            options.environment = config.environment
            options.sendDefaultPii = false
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            options.tracesSampleRate = NSNumber(value: config.tracesSampleRate)
            options.configureProfiling = { profileOptions in
                profileOptions.sessionSampleRate = config.profilesSessionSampleRate
                profileOptions.lifecycle = .trace
            }
            options.enableAppHangTracking = true
            options.appHangTimeoutInterval = appHangTimeout
            options.enableCaptureFailedRequests = true
            options.failedRequestStatusCodes = [HttpStatusCodeRange(min: 500, max: 599)]
            options.beforeSend = { event in
                if let request = event.request, let url = request.url {
                    request.url = redactSensitiveURL(url)
                }
                return event
            }
        }
    }
}
