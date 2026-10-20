import Foundation

/// UI harnesses exercise real views without starting live disk or process probes.
enum ApplicationRunMode: Equatable {
    case normal
    case unitTests
    case uiHarness

    var allowsLiveProbes: Bool { self == .normal }

    static var current: Self {
        detect(arguments: ProcessInfo.processInfo.arguments,
               environment: ProcessInfo.processInfo.environment,
               xctestLoaded: NSClassFromString("XCTestCase") != nil
                   || NSClassFromString("XCTest.XCTestCase") != nil)
    }

    static func detect(arguments: [String], environment: [String: String], xctestLoaded: Bool) -> Self {
        if xctestLoaded || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil || arguments.contains("-XCTest") {
            return .unitTests
        }
        if arguments.contains("-HogHunterScreenshot") || arguments.contains("-HogHunterUISmoke") {
            return .uiHarness
        }
        return .normal
    }
}
