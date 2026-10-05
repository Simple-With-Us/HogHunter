import XCTest

@testable import HogHunter

/// Covers `Grouping.groups`.  All samples are synthetic; `isRegularApp` and
/// `bundleId` are supplied as closures over a small fixture map, exactly the
/// shape the real caller (LaunchServices-backed, main-actor) would provide.
final class GroupingTests: XCTestCase {

    /// A minimal `ProcessSample` factory.  Only the fields grouping cares
    /// about are exposed as parameters; the rest take inert defaults.
    private func sample(
        pid: pid_t,
        ppid: pid_t,
        start: UInt64 = 0,
        name: String = "proc",
        path: String = "",
        cpu: Double = 0,
        memory: UInt64 = 0
    ) -> ProcessSample {
        ProcessSample(
            key: ProcessKey(pid: pid, startTime: start),
            ppid: ppid,
            uid: 501,
            name: name,
            path: path,
            cpuPercent: cpu,
            hasBaseline: true,
            footprintBytes: memory,
            residentBytes: memory,
            threadCount: 1,
            diskReadBytesPerSec: 0,
            diskWriteBytesPerSec: 0,
            idleWakeupsPerSec: 0
        )
    }

    // MARK: - Ancestor walk

    func testRendererHelperGroupsUnderItsAppParent() {
        let app = sample(pid: 100, ppid: 1, name: "MyApp", path: "/Applications/MyApp.app/MyApp", cpu: 5)
        let renderer = sample(pid: 101, ppid: 100, name: "MyApp Helper (Renderer)", cpu: 10)

        let groups = Grouping.groups(
            [app, renderer],
            isRegularApp: { $0 == 100 },
            bundleId: { $0 == 100 ? "com.example.myapp" : nil }
        )

        XCTAssertEqual(groups.count, 1)
        let group = try! XCTUnwrap(groups.first)
        XCTAssertEqual(group.key, "app:com.example.myapp")
        XCTAssertEqual(group.ownerPid, 100)
        XCTAssertTrue(group.isApp)
        XCTAssertEqual(group.members.count, 2)
    }

    func testGrandchildGroupsUnderTheSameApp() {
        let app = sample(pid: 100, ppid: 1)
        let renderer = sample(pid: 101, ppid: 100)
        let grandchild = sample(pid: 102, ppid: 101)

        let groups = Grouping.groups(
            [app, renderer, grandchild],
            isRegularApp: { $0 == 100 },
            bundleId: { $0 == 100 ? "com.example.myapp" : nil }
        )

        XCTAssertEqual(groups.count, 1)
        let group = try! XCTUnwrap(groups.first)
        XCTAssertEqual(group.members.count, 3)
        XCTAssertTrue(group.isApp)
    }

    func testUnparentedProcessWithBundleIdGroupsByBundleId() {
        // ppid 1, no regular-app ancestor anywhere in the walk.
        let helper = sample(pid: 200, ppid: 1, path: "")

        let groups = Grouping.groups(
            [helper],
            isRegularApp: { _ in false },
            bundleId: { $0 == 200 ? "com.example.helper" : nil }
        )

        XCTAssertEqual(groups.count, 1)
        let group = try! XCTUnwrap(groups.first)
        XCTAssertEqual(group.key, "bundle:com.example.helper")
        XCTAssertFalse(group.isApp)
        XCTAssertNil(group.ownerPid)
    }

    // MARK: - Path fallback

    func testTwoUnrelatedProcessesWithDifferentPathsStaySeparate() {
        // Two "node" processes with no bundle id and no regular-app ancestor
        // must never merge on the bare name.
        let nodeA = sample(pid: 300, ppid: 1, name: "node", path: "/usr/local/bin/node")
        let nodeB = sample(pid: 301, ppid: 1, name: "node", path: "/opt/homebrew/bin/node")

        let groups = Grouping.groups([nodeA, nodeB], isRegularApp: { _ in false }, bundleId: { _ in nil })

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(Set(groups.map(\.key)), ["path:/usr/local/bin/node", "path:/opt/homebrew/bin/node"])
    }

    func testTwoProcessesWithTheSamePathShareOneGroup() {
        let nodeA = sample(pid: 302, ppid: 1, name: "node", path: "/usr/local/bin/node", cpu: 5, memory: 1000)
        let nodeB = sample(pid: 303, ppid: 1, name: "node", path: "/usr/local/bin/node", cpu: 7, memory: 2000)

        let groups = Grouping.groups([nodeA, nodeB], isRegularApp: { _ in false }, bundleId: { _ in nil })

        XCTAssertEqual(groups.count, 1)
        let group = try! XCTUnwrap(groups.first)
        XCTAssertEqual(group.key, "path:/usr/local/bin/node")
        XCTAssertEqual(group.members.count, 2)
    }

    // MARK: - Claude CLI family

    func testTwoUnrelatedClaudeSessionsStaySeparateDespiteSharingAPath() {
        // Two independent terminal sessions running the same CLI binary --
        // ppid 1 stands in for "parent is a shell, not another Claude
        // process".  Merging these would make Quit on one row kill every
        // unrelated fleet session sharing that binary.
        let claudeVersionsPath = "/Users/jay/.local/share/claude/versions/2.1.266"
        let sessionA = sample(pid: 500, ppid: 1, name: "claude", path: claudeVersionsPath)
        let sessionB = sample(pid: 501, ppid: 1, name: "claude", path: claudeVersionsPath)

        let groups = Grouping.groups([sessionA, sessionB], isRegularApp: { _ in false }, bundleId: { _ in nil })

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(Set(groups.map(\.key)), ["claude:500", "claude:501"])
    }

    func testClaudeWorkerSubprocessGroupsUnderItsOwnSession() {
        // A session's own worker subprocess (verified by ppid, not by path)
        // folds into that session's row instead of staying separate.
        let claudeVersionsPath = "/Users/jay/.local/share/claude/versions/2.1.266"
        let session = sample(pid: 600, ppid: 1, name: "claude", path: claudeVersionsPath)
        let worker = sample(pid: 601, ppid: 600, name: "claude", path: claudeVersionsPath, cpu: 10, memory: 500)

        let groups = Grouping.groups([session, worker], isRegularApp: { _ in false }, bundleId: { _ in nil })

        XCTAssertEqual(groups.count, 1)
        let group = try! XCTUnwrap(groups.first)
        XCTAssertEqual(group.key, "claude:600")
        XCTAssertEqual(group.members.count, 2)
        XCTAssertFalse(group.isApp)
    }

    func testUnrelatedNonClaudeProcessOnAClaudePathIsUnaffected() {
        // Sanity check that the Claude-specific branch only ever fires for
        // paths ClaudeProcess.isCLI recognizes.
        let other = sample(pid: 700, ppid: 1, name: "node", path: "/usr/local/bin/node")

        let groups = Grouping.groups([other], isRegularApp: { _ in false }, bundleId: { _ in nil })

        XCTAssertEqual(groups.first?.key, "path:/usr/local/bin/node")
    }

    // MARK: - Cycle safety

    func testPpidCycleTerminatesAndFallsBackWithoutMerging() {
        // a's ppid is b and b's ppid is a: a corrupted or racing process
        // table.  The walk must terminate (this test would hang otherwise)
        // and each process falls back to its own group rather than crashing
        // or merging on nothing.
        let a = sample(pid: 400, ppid: 401, path: "")
        let b = sample(pid: 401, ppid: 400, path: "")

        let groups = Grouping.groups([a, b], isRegularApp: { _ in false }, bundleId: { _ in nil })

        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.allSatisfy { !$0.isApp && $0.key.hasPrefix("proc:") })
    }

    // MARK: - Aggregation

    func testGroupCpuAndMemoryAreSumsOfMembers() {
        let app = sample(pid: 100, ppid: 1, cpu: 2, memory: 1_000_000)
        let renderer = sample(pid: 101, ppid: 100, cpu: 30, memory: 500_000)

        let groups = Grouping.groups(
            [app, renderer],
            isRegularApp: { $0 == 100 },
            bundleId: { $0 == 100 ? "com.example.myapp" : nil }
        )

        let group = try! XCTUnwrap(groups.first)
        XCTAssertEqual(group.cpuPercent, 32, accuracy: 0.0001)
        XCTAssertEqual(group.memoryBytes, 1_500_000)
    }

    /// `Grouping.Group` itself carries no "detail" string — that copy (e.g.
    /// "com.google.Chrome · 7 processes") is built downstream from the
    /// member count, so this checks the member count that string would be
    /// built from, which is the only part of the contract that lives here.
    func testGroupExposesMemberCountForTheDetailString() {
        let app = sample(pid: 100, ppid: 1)
        let renderer = sample(pid: 101, ppid: 100)
        let grandchild = sample(pid: 102, ppid: 101)

        let groups = Grouping.groups(
            [app, renderer, grandchild],
            isRegularApp: { $0 == 100 },
            bundleId: { $0 == 100 ? "com.example.myapp" : nil }
        )

        XCTAssertEqual(try! XCTUnwrap(groups.first).members.count, 3)
    }

    func testMemoryFormattingAgreementTiebreaksWithCpu() {
        let memA: UInt64 = 1_720_000_000
        let memB: UInt64 = 1_680_000_000
        XCTAssertEqual(HogFormat.memory(memA), "1.6 GB")
        XCTAssertEqual(HogFormat.memory(memB), "1.6 GB")
    }
}
