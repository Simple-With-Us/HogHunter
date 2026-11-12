import XCTest
@testable import HogHunter

final class ApplicationRunModeTests: XCTestCase {
    func testEveryTestHostSignalDisablesLiveProbes() {
        for environment in [
            ["XCTestConfigurationFilePath": "fixture"],
            ["XCTestBundlePath": "fixture"],
            ["XCTestSessionIdentifier": "fixture"],
            ["XCInjectBundleInto": "fixture"]
        ] {
            XCTAssertFalse(ApplicationRunMode.detect(arguments: [], environment: environment, xctestLoaded: false).allowsLiveProbes)
        }
        XCTAssertFalse(ApplicationRunMode.detect(arguments: ["HogHunter", "-XCTest"], environment: [:], xctestLoaded: false).allowsLiveProbes)
        XCTAssertFalse(ApplicationRunMode.detect(arguments: ["HogHunter", "/path/to/Tests.xctest"], environment: [:], xctestLoaded: false).allowsLiveProbes)
        XCTAssertFalse(ApplicationRunMode.detect(arguments: [], environment: [:], xctestLoaded: true).allowsLiveProbes)
        XCTAssertFalse(ApplicationRunMode.current.allowsLiveProbes)
    }

    func testUIHarnessFlagsDisableLiveProbesButOrdinaryLaunchDoesNot() {
        for flag in [HarnessArgument.screenshot, HarnessArgument.uiSmoke] {
            XCTAssertEqual(ApplicationRunMode.detect(arguments: ["HogHunter", flag], environment: [:], xctestLoaded: false), .uiHarness)
        }
        XCTAssertTrue(ApplicationRunMode.detect(arguments: ["HogHunter"], environment: [:], xctestLoaded: false).allowsLiveProbes)
    }
}
