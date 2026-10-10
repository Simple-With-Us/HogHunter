import XCTest
@testable import HogHunter

/// The single-instance guard exists because two Hog Hunters produce two
/// independent Full Disk Access prompts, and denying one leaves the other
/// asking forever.  Every case here is a way that guard could be wrong in a
/// way nobody notices: a harness launch that gets swallowed, a test host that
/// kills its own suite, or a guard that never fires.
final class SingleInstanceTests: XCTestCase {
    // MARK: - The failure it prevents

    func testASecondCopyHandsOverAndQuits() {
        XCTAssertTrue(
            SingleInstance.shouldHandOver(
                argumentStrings: ["/Applications/Hog Hunter.app/Contents/MacOS/HogHunter"],
                isRunningTests: false,
                ownPID: 200,
                runningPIDs: [100]
            )
        )
    }

    /// The guard must not mistake itself for the rival copy.
    func testItDoesNotHandOverToItself() {
        XCTAssertFalse(
            SingleInstance.shouldHandOver(
                argumentStrings: ["/Applications/Hog Hunter.app/Contents/MacOS/HogHunter"],
                isRunningTests: false,
                ownPID: 200,
                runningPIDs: [200]
            )
        )
    }

    func testTheFirstLaunchIsLeftAlone() {
        XCTAssertFalse(
            SingleInstance.shouldHandOver(
                argumentStrings: ["/Applications/Hog Hunter.app/Contents/MacOS/HogHunter"],
                isRunningTests: false,
                ownPID: 200,
                runningPIDs: []
            )
        )
    }

    // MARK: - Harness launches must never be intercepted

    /// CI launches the app on machines that also have an installed copy.  A
    /// guard that fires here would terminate the capture process and the lane
    /// would screenshot nothing, with a green build.
    func testTheScreenshotHarnessIsNeverIntercepted() {
        XCTAssertFalse(
            SingleInstance.shouldHandOver(
                argumentStrings: ["/Applications/Hog Hunter.app/Contents/MacOS/HogHunter", HarnessArgument.screenshot],
                isRunningTests: false,
                ownPID: 200,
                runningPIDs: [100]
            ),
            "the screenshot harness must launch even when an installed copy is running"
        )
    }

    func testTheUISmokeHarnessIsNeverIntercepted() {
        XCTAssertFalse(
            SingleInstance.shouldHandOver(
                argumentStrings: ["/Applications/Hog Hunter.app/Contents/MacOS/HogHunter", HarnessArgument.uiSmoke],
                isRunningTests: false,
                ownPID: 200,
                runningPIDs: [100]
            )
        )
    }

    // MARK: - The test host

    /// `xcodebuild test` runs the app as the test host, so the process list
    /// legitimately contains it.  Terminating here takes the whole suite down,
    /// and the failure looks like a crash rather than a guard bug.
    func testTheXCTestHostIsNeverTerminated() {
        XCTAssertFalse(
            SingleInstance.shouldHandOver(
                argumentStrings: ["/Applications/Hog Hunter.app/Contents/MacOS/HogHunter"],
                isRunningTests: true,
                ownPID: 200,
                runningPIDs: [100]
            )
        )
    }

    /// Test-host exemption outranks the harness arguments, so a suite that
    /// happens to pass a harness flag still is not terminated.
    func testTestHostExemptionWinsOverHarnessFlags() {
        XCTAssertFalse(
            SingleInstance.shouldHandOver(
                argumentStrings: [HarnessArgument.screenshot, HarnessArgument.uiSmoke],
                isRunningTests: true,
                ownPID: 200,
                runningPIDs: [100]
            )
        )
    }

    // MARK: - The constant the delegate and the guard share

    /// A typo in either place is a silent failure to intercept, which is the
    /// same class of bug as the duplicate prompts this guard prevents.
    func testHarnessArgumentsAreDistinctAndPrefixed() {
        XCTAssertNotEqual(HarnessArgument.screenshot, HarnessArgument.uiSmoke)
        for argument in [HarnessArgument.screenshot, HarnessArgument.uiSmoke] {
            XCTAssertTrue(argument.hasPrefix("-HogHunter"), "\(argument) lost its namespace prefix")
        }
    }

    /// A bundle identifier that is missing or empty must not be treated as a
    /// wildcard that matches every running app on the machine.
    func testAMissingBundleIdentifierFindsNoCopies() {
        XCTAssertEqual(RunningCopies.otherPIDs(bundleIdentifier: nil, ownPID: 200), [])
        XCTAssertEqual(RunningCopies.otherPIDs(bundleIdentifier: "", ownPID: 200), [])
    }
}