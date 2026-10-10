import AppKit
import Foundation

/// Decides whether a second Hog Hunter should hand over to the copy already
/// running and exit, instead of starting its own.
///
/// Pure, so it can be tested without launching an app.  The decision has three
/// inputs that all have to be checked, and getting any of them wrong is
/// invisible until it bites:
///
/// 1. **Another copy is actually running.**  Without the guard a second launch
///    starts a second app, and because macOS grants Full Disk Access per
///    binary *and* pid, two copies probe protected paths independently and the
///    owner gets the same permission prompt twice.  Denying one leaves the
///    other asking forever, which is what was observed.
///
/// 2. **This is not a deliberate harness launch.**  CI launches the app with
///    `-HogHunterScreenshot` or `-HogHunterUISmoke`, and it does so on machines
///    where an installed copy may also be running.  A harness launch must never
///    be intercepted or the capture lane silently produces a screenshot of
///    nothing.
///
/// 3. **This is not the XCTest host.**  `xcodebuild test` runs the app as the
///    test host, so `NSRunningApplication` legitimately lists it.  Terminating
///    there would take the whole suite down.
enum SingleInstance {
    /// True when this process should activate the running copy and quit.
    ///
    /// - Parameters:
    ///   - argumentStrings: `CommandLine.arguments`.
    ///   - isRunningTests: whether an XCTest bundle is loaded in this process.
    ///   - ownPID: this process's identifier, so it never counts as the rival.
    ///   - runningPIDs: every other pid sharing the bundle identifier.
    static func shouldHandOver(
        argumentStrings: [String],
        isRunningTests: Bool,
        ownPID: pid_t,
        runningPIDs: [pid_t]
    ) -> Bool {
        // 2 and 3 first: a harness or test launch is always legitimate, and
        // answering that before looking at the process list keeps this
        // readable rather than three conditions tangled into one `if`.
        if isRunningTests { return false }
        if argumentStrings.contains(HarnessArgument.screenshot) { return false }
        if argumentStrings.contains(HarnessArgument.uiSmoke) { return false }

        // 1: a rival copy, excluding ourselves.  `.activationPolicy == .accessory`
        // is not checked: the rival can be a regular-app window open, and it is
        // still the copy that owns the menu bar item and the Keychain.
        return runningPIDs.contains { $0 != ownPID }
    }
}

/// Launch arguments that mark a harness launch.  Kept in one place because the
/// guard and the delegate both need to agree on them; a typo in either used to
/// be a silent failure to intercept.
enum HarnessArgument {
    static let screenshot = "-HogHunterScreenshot"
    static let uiSmoke = "-HogHunterUISmoke"
}

/// Finds every other running copy that shares this app's bundle identifier.
enum RunningCopies {
    static func otherPIDs(bundleIdentifier: String?, ownPID: pid_t) -> [pid_t] {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return [] }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .map(\.processIdentifier)
            .filter { $0 != ownPID }
    }
}