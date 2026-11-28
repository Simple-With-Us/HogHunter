import XCTest
@testable import HogHunter

/// AGENTS.md ("Copy"): the theme default is Light when no stored preference
/// exists, and a stored Light, System or Dark choice is preserved.  This
/// supersedes the older System-when-unset fallback.
@MainActor
final class AppearanceDefaultTests: XCTestCase {
    private func store(in suite: String) -> HogStore {
        let defaults = UserDefaults(suiteName: suite)!
        return HogStore(defaults: defaults)
    }

    func testNoStoredPreferenceDefaultsToLight() {
        let suite = "hoghunter.tests.appearance.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        XCTAssertEqual(store(in: suite).appearance, .light)
    }

    func testAStoredPreferenceStillWinsOverTheLightDefault() {
        for choice in AppearanceChoice.allCases {
            let suite = "hoghunter.tests.appearance.\(UUID().uuidString)"
            defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            UserDefaults(suiteName: suite)?.set(choice.rawValue, forKey: HogStore.Key.appearance)
            XCTAssertEqual(store(in: suite).appearance, choice, "stored \(choice.rawValue) must not be replaced by the Light default")
        }
    }
}
