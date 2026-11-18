import XCTest
@testable import HogHunter

/// Tests for the regimen model: what a scheduled unattended clean is allowed
/// to do, and what a corrupt stored regimen must never be able to do.
final class CleanRegimenTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "hoghunter.tests.regimen.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    // MARK: - Defaults

    func testEmptyRulesDoNotSelectEveryScannedItem() {
        let item = CleanItem(
            category: .userCaches,
            title: "cache",
            subtitle: "cache",
            url: URL(fileURLWithPath: "/tmp/hoghunter-regimen-test"),
            bytes: 10,
            fileCount: 1,
            lastModified: nil,
            isSelected: true,
            detail: nil
        )
        let empty = CleanRegimenRunner.pendingItems(from: [item], rules: [])
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertEqual(empty.skipReason, "No cleaning rules are enabled.")

        let unmatched = CleanRegimenRunner.pendingItems(from: [item], rules: ["logs"])
        XCTAssertTrue(unmatched.items.isEmpty)
        XCTAssertEqual(unmatched.skipReason, "Nothing matched the enabled rules.")

        let matched = CleanRegimenRunner.pendingItems(from: [item], rules: ["dev-caches"])
        XCTAssertEqual(matched.items.map(\.title), ["cache"])
        XCTAssertNil(matched.skipReason)
    }

    func testAppCachesAndAgentStateRulesSelectItems() {
        func item(category: CleanCategory, title: String) -> CleanItem {
            CleanItem(
                category: category,
                title: title,
                subtitle: title,
                url: URL(fileURLWithPath: "/tmp/hoghunter-regimen-\(title)"),
                bytes: 10,
                fileCount: 1,
                lastModified: nil,
                isSelected: true,
                detail: nil
            )
        }
        let cache = item(category: .userCaches, title: "cache")
        let agent = item(category: .aiArtifacts, title: "agent")

        // Both rules are in defaultRules and schedulableRules, so the selector
        // has to be able to produce them.  A rule nothing maps to is a dead
        // toggle: enabling it selects nothing.
        let appCaches = CleanRegimenRunner.pendingItems(from: [cache, agent], rules: ["app-caches"])
        XCTAssertEqual(appCaches.items.map(\.title), ["cache"])
        let agentState = CleanRegimenRunner.pendingItems(from: [cache, agent], rules: ["agent-state"])
        XCTAssertEqual(agentState.items.map(\.title), ["agent"])

        // A regimen persisted before the app-caches rule existed carries
        // dev-caches, and must keep selecting the same items.
        let legacy = CleanRegimenRunner.pendingItems(from: [cache, agent], rules: ["dev-caches"])
        XCTAssertEqual(legacy.items.map(\.title), ["cache"])
    }

    func testTempFilesRuleIsDecoupledFromTrash() {
        func item(category: CleanCategory, title: String) -> CleanItem {
            CleanItem(
                category: category,
                title: title,
                subtitle: title,
                url: URL(fileURLWithPath: "/tmp/hoghunter-regimen-\(title)"),
                bytes: 10,
                fileCount: 1,
                lastModified: nil,
                isSelected: true,
                detail: nil
            )
        }
        let trash = item(category: .trash, title: "trash")
        let temp = item(category: .tempFiles, title: "tmp")
        XCTAssertEqual(CleanRegimenRunner.ruleName(for: temp), "tmp-files")

        let onlyTemp = CleanRegimenRunner.pendingItems(from: [trash, temp], rules: ["tmp-files"])
        XCTAssertEqual(onlyTemp.items.map(\.title), ["tmp"])
        XCTAssertNil(onlyTemp.skipReason)

        XCTAssertTrue(CleanRegimen.schedulableRules.contains("tmp-files"))
        // Owner directive 2026-11-17: tmp-files is a default rule, like
        // snapshots.  Default-on scopes the category into a fresh regimen;
        // what a run may delete still rests on the scan's per-item verdicts,
        // and scanTempFiles pre-selects nothing.
        XCTAssertTrue(CleanRegimen.defaultRules.contains("tmp-files"))
        XCTAssertTrue(CleanRegimen.defaultRules.contains("snapshots"))
    }

    func testStaleBackupsNeverScheduleUnattended() {
        let backup = CleanItem(
            category: .staleBackups,
            title: "state.vscdb.bak-old",
            subtitle: "backup",
            url: URL(fileURLWithPath: "/tmp/hoghunter-regimen-backup"),
            bytes: 10,
            fileCount: 1,
            lastModified: nil,
            isSelected: true,
            detail: nil
        )
        XCTAssertEqual(CleanRegimenRunner.ruleName(for: backup), "ask-first")
        let pending = CleanRegimenRunner.pendingItems(from: [backup], rules: Set(CleanRegimen.schedulableRules))
        XCTAssertTrue(pending.items.isEmpty, "no schedulable rule may take tool-made backups unattended")
    }

    func testNoRegimenRuleSelectsOrScansTheTrash() {
        // config/reclaim-policy.json says neverEmptyTrash, and DiskCleaner.clean
        // removes a Trash item permanently.  This used to map to temp-scratch,
        // a default rule, so a turned-on regimen emptied ~/.Trash unattended.
        let trash = CleanItem(
            category: .trash,
            title: "trash",
            subtitle: "trash",
            url: URL(fileURLWithPath: "/tmp/hoghunter-regimen-trash"),
            bytes: 10,
            fileCount: 1,
            lastModified: nil,
            isSelected: true,
            detail: nil
        )
        XCTAssertTrue(CleanRegimenRunner.ruleNames(for: trash).isEmpty)
        XCTAssertEqual(CleanRegimenRunner.ruleName(for: trash), "")

        let everyRule = Set(CleanRegimen.schedulableRules).union(CleanRegimen.defaultRules)
        XCTAssertFalse(CleanRegimenRunner.scanCategories(for: everyRule).contains(.trash))
        for rule in everyRule {
            let pending = CleanRegimenRunner.pendingItems(from: [trash], rules: [rule])
            XCTAssertTrue(pending.items.isEmpty, "\(rule) must not select the Trash")
        }
        XCTAssertTrue(CleanRegimenRunner.pendingItems(from: [trash], rules: everyRule).items.isEmpty)
    }

    func testTheRuleThatOnlyEverSelectedTheTrashIsGone() {
        // temp-scratch's one job in the regimen was the Trash mapping.  A stored
        // regimen naming it must not keep a default-on switch that does nothing.
        XCTAssertFalse(CleanRegimen.defaultRules.contains("temp-scratch"))
        XCTAssertFalse(CleanRegimen.schedulableRules.contains("temp-scratch"))
        var stored = CleanRegimen()
        stored.enabledRules = ["temp-scratch", "logs"]
        XCTAssertEqual(stored.sanitized().enabledRules, ["logs"])
    }

    func testEngineOnlyRulesAreNotOfferedToTheRegimen() {
        // The regimen runs DiskCleaner.  These live only in the engine, so
        // a stored regimen naming them is left with nothing rather than a
        // switch that looks on and does nothing.  app-staging, sqlite-wal,
        // brew, and simulator-runtimes were offered until 2026-11-18 despite
        // no cleaner category ever answering to them.
        for rule in ["duplicate-sim-runtimes", "tool-versions", "xcode-scratch", "stale-build-output",
                     "app-staging", "sqlite-wal", "brew", "simulator-runtimes"] {
            XCTAssertFalse(CleanRegimen.schedulableRules.contains(rule), rule)
            XCTAssertFalse(CleanRegimen.defaultRules.contains(rule), rule)
            var regimen = CleanRegimen()
            regimen.enabledRules = [rule]
            XCTAssertEqual(regimen.sanitized().enabledRules, [], "sanitizing must drop \(rule)")
            XCTAssertTrue(CleanRegimenRunner.scanCategories(for: [rule]).isEmpty, rule)
        }
    }

    func testRegimenIsOffByDefault() {
        // An unattended delete is a different promise than a button press.
        XCTAssertFalse(CleanRegimen().isEnabled)
    }

    func testDefaultsAreValid() {
        let r = CleanRegimen()
        XCTAssertTrue(r.isValid)
        XCTAssertGreaterThanOrEqual(r.targetsPerChunk, 1)
        XCTAssertTrue(r.createSnapshotBeforeClean, "an unattended clean needs a rollback point")
    }

    func testDefaultRulesExcludeAskFirst() {
        // Nothing in ask-first is ever deleted without a human, so a regimen
        // has no business listing it.
        XCTAssertFalse(CleanRegimen.defaultRules.contains("ask-first"))
        for rule in CleanRegimen.defaultRules {
            XCTAssertTrue(CleanRegimen.schedulableRules.contains(rule), "\(rule) is not schedulable")
        }
    }

    // MARK: - Sanitizing a stored value

    func testSanitizeRepairsOutOfRangeValues() {
        var r = CleanRegimen()
        r.intervalHours = 0
        r.targetsPerChunk = 0
        r.pressuredTargetsPerChunk = -3
        r.chunkPauseSeconds = .nan
        r.expensiveTierFreeGB = -1
        let fixed = r.sanitized()
        XCTAssertTrue(fixed.isValid)
        XCTAssertGreaterThanOrEqual(fixed.targetsPerChunk, 1)
        XCTAssertGreaterThanOrEqual(fixed.pressuredTargetsPerChunk, 1)
        XCTAssertEqual(fixed.chunkPauseSeconds, 5, "NaN pause falls back to the default")
        XCTAssertGreaterThan(fixed.expensiveTierFreeGB, 0)
    }

    func testSanitizeDropsRulesThatAreNotSchedulable() {
        var r = CleanRegimen()
        // A hand-edited or future-written blob must not smuggle in a rule the
        // scheduler has no business running.  Names the regimen once offered
        // and no longer does (brew, app-staging) drop the same way, which is
        // what migrates stored regimens off them.
        r.enabledRules = ["dev-caches", "ask-first", "totally-made-up", "brew", "app-staging"]
        let fixed = r.sanitized()
        XCTAssertEqual(fixed.enabledRules, ["dev-caches"])
    }

    func testSanitizeCapsAbsurdInterval() {
        var r = CleanRegimen()
        r.intervalHours = 1_000_000
        XCTAssertEqual(r.sanitized().intervalHours, 24 * 14)
    }

    func testSanitizeHandlesInfiniteInterval() {
        var r = CleanRegimen()
        r.intervalHours = .infinity
        XCTAssertTrue(r.sanitized().isValid)
    }

    // MARK: - Persistence

    func testRoundTripsThroughDefaults() {
        // Exercised through a private defaults suite so the test never touches
        // the real user's saved regimen.
        let suite = "hoghunter.tests.regimen.\(UUID().uuidString)"
        let defaults = makeDefaults()

        var r = CleanRegimen()
        r.isEnabled = true
        r.intervalHours = 6
        r.pressuredTargetsPerChunk = 1
        r.enabledRules = ["logs", "brew"]

        let data = try? JSONEncoder().encode(r)
        defaults.set(data, forKey: "hoghunter.cleaner.regimen")
        let decoded = try? JSONDecoder().decode(CleanRegimen.self, from: data ?? Data())
        XCTAssertEqual(decoded, r)

        defaults.removePersistentDomain(forName: suite)
    }

    func testUnknownFieldsDoNotBreakDecoding() {
        // Forward compatibility: a blob written by a newer build must still
        // load, and must not take the app down with it.
        let json = """
        {"isEnabled":true,"intervalHours":8,"someFieldFromTheFuture":{"a":1}}
        """.data(using: .utf8)!
        let decoded = try? JSONDecoder().decode(CleanRegimen.self, from: json)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.isEnabled, true)
        XCTAssertEqual(decoded?.intervalHours, 8)
    }

    // MARK: - Reachability honesty (2026-11-17)

    /// One pre-selected item per category, so only the rule mapping and
    /// the scan tier can keep it from a regimen.
    private func reachabilityItem(for category: CleanCategory) -> CleanItem {
        CleanItem(
            category: category,
            title: category.rawValue,
            subtitle: category.rawValue,
            url: URL(fileURLWithPath: "/tmp/hoghunter-reachability-\(category.rawValue)"),
            bytes: 10,
            fileCount: 1,
            lastModified: nil,
            isSelected: true,
            detail: nil
        )
    }

    func testEverySchedulableRuleSelectsAStandardTierCategory() {
        // The regimen scans at the standard tier, so a schedulable rule is
        // honest only if it selects at least one category that tier
        // includes.  A rule selecting nothing -- or only Extreme-only
        // categories -- is a dead switch in the regimen's vocabulary.
        for rule in CleanRegimen.schedulableRules {
            let categories = CleanRegimenRunner.scanCategories(for: [rule])
            XCTAssertFalse(categories.isEmpty, "\(rule) selects no category")
            XCTAssertTrue(
                categories.contains { CleanTier.standard.isCategoryIncluded($0) },
                "\(rule) selects only categories the regimen scan tier excludes"
            )
        }
    }

    func testEveryDefaultRuleSelectsSomething() {
        for rule in CleanRegimen.defaultRules {
            XCTAssertFalse(
                CleanRegimenRunner.scanCategories(for: [rule]).isEmpty,
                "default rule \(rule) selects nothing"
            )
        }
    }

    func testEveryCategoryMappingIsHonest() {
        // For every category exactly one of three honest states holds: it
        // answers to no rule (the Trash, reachable only through the owner's
        // Trash valve), it answers only to ask-first (review-only), or it
        // answers to schedulable rules and the regimen's standard scan tier
        // includes it.
        for category in CleanCategory.allCases {
            let names = CleanRegimenRunner.ruleNames(for: reachabilityItem(for: category))
            if names.isEmpty {
                XCTAssertEqual(category, .trash, "\(category) answers to no rule")
            } else if names == ["ask-first"] {
                XCTAssertFalse(
                    CleanRegimenRunner.scanCategories(for: Set(CleanRegimen.schedulableRules)).contains(category),
                    "\(category) is ask-first yet reachable by a schedulable rule"
                )
            } else {
                XCTAssertTrue(
                    names.isSubset(of: Set(CleanRegimen.schedulableRules)),
                    "\(category) answers to unschedulable rules \(names)"
                )
                XCTAssertTrue(
                    CleanTier.standard.isCategoryIncluded(category),
                    "\(category) answers to \(names) but the regimen scan tier excludes it"
                )
            }
        }
    }

    func testReviewOnlyCategoriesStayUnreachableUnattended() {
        // Orphaned app data, local AI models, and large/old user files
        // joined tool-made backups and stale temp repos in ask-first on
        // 2026-11-18: no schedulable rule -- and not the full default set
        // either -- may hand their items to a regimen.
        let reviewOnly: [CleanCategory] = [.orphanedData, .localAIModels, .largeAndOldFiles, .staleBackups, .staleTempRepos]
        for category in reviewOnly {
            let candidate = reachabilityItem(for: category)
            XCTAssertEqual(CleanRegimenRunner.ruleName(for: candidate), "ask-first", "\(category)")
            let byEveryRule = CleanRegimenRunner.pendingItems(
                from: [candidate], rules: Set(CleanRegimen.schedulableRules))
            XCTAssertTrue(byEveryRule.items.isEmpty, "\(category) reached by a schedulable rule")
            let byDefaults = CleanRegimenRunner.pendingItems(
                from: [candidate], rules: CleanRegimen.defaultRules)
            XCTAssertTrue(byDefaults.items.isEmpty, "\(category) reached by the default rules")
        }
    }

    func testAgentStateReachesAIArtifactsUnderTheRegimenScan() {
        // The positive half of the 2026-11-18 fix: the agent-state rule
        // finally selects its category, and the category sits in the tier
        // the regimen scans.  (What a run then deletes still rests on the
        // scan's per-item pre-selection, which scanAIArtifacts grants only
        // to abandoned update packages.)
        XCTAssertTrue(CleanRegimenRunner.scanCategories(for: ["agent-state"]).contains(.aiArtifacts))
        XCTAssertTrue(CleanTier.standard.isCategoryIncluded(.aiArtifacts))
        let pending = CleanRegimenRunner.pendingItems(
            from: [reachabilityItem(for: .aiArtifacts)], rules: ["agent-state"])
        XCTAssertEqual(pending.items.count, 1)
    }

    func testDefaultExclusionsExcludeNoCategory() {
        // Fresh state excludes nothing: snapshot thinning is standard
        // maintenance, and the old apfsSnapshots default silently vetoed
        // it even for an owner who enabled the snapshots rule.  A stored
        // exclusion is user state and still wins.
        XCTAssertTrue(CleanerExclusions().excludedCategories.isEmpty)
        let stored = try? JSONDecoder().decode(
            CleanerExclusions.self,
            from: Data(#"{"excludedCategories":["apfsSnapshots"],"excludedPaths":[]}"#.utf8))
        XCTAssertEqual(stored?.isCategoryExcluded(.apfsSnapshots), true)
    }
}
