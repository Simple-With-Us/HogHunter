import XCTest
@testable import HogHunter

/// HH-212: the phone Overview's busiest ranking is a total order.  The first
/// draft used an epsilon comparator (treat |a-b| < 0.05 as a tie and fall
/// through to memory), which is not transitive: CPU 0/memory 3, CPU 0.04/
/// memory 2 and CPU 0.08/memory 1 form a cycle.  These tests pin the exact
/// total order so that shape of bug cannot come back.
final class CompanionOverviewRankingTests: XCTestCase {
    private func row(_ id: String, _ name: String, cpu: Double? = nil, memory: UInt64? = nil) -> CompanionRow {
        CompanionRow(id: id, name: name, detail: "", cpuText: "", memoryText: "",
                     severity: "calm", isApp: true, cpuPercent: cpu, memoryBytes: memory)
    }

    private func ids(_ rows: [CompanionRow]) -> [String] { rows.map(\.id) }

    func testExactDescendingCPU() {
        let rows = [row("a", "A", cpu: 1), row("b", "B", cpu: 3), row("c", "C", cpu: 2)]
        XCTAssertEqual(ids(rows.rankedByActivity()), ["b", "c", "a"])
    }

    /// The reviewer-found cycle: with an epsilon of 0.05 these three rows
    /// order inconsistently depending on which pair is compared first.  The
    /// exact order is simply descending CPU; memory never gets consulted.
    func testEpsilonCycleRegression() {
        let rows = [
            row("x", "X", cpu: 0, memory: 3),
            row("y", "Y", cpu: 0.04, memory: 2),
            row("z", "Z", cpu: 0.08, memory: 1),
        ]
        XCTAssertEqual(ids(rows.rankedByActivity()), ["z", "y", "x"])
        XCTAssertEqual(ids(rows.reversed().rankedByActivity()), ["z", "y", "x"])
    }

    func testTiesFallThroughMemoryThenNameThenID() {
        let rows = [
            row("2", "Same", cpu: 5, memory: 10),
            row("1", "Same", cpu: 5, memory: 10),
            row("m", "B-name", cpu: 5, memory: 20),
            row("n", "A-name", cpu: 5, memory: 20),
            row("h", "High-mem", cpu: 5, memory: 30),
        ]
        XCTAssertEqual(ids(rows.rankedByActivity()), ["h", "n", "m", "1", "2"])
    }

    func testMissingNumbersRankLast() {
        let rows = [
            row("old", "Old Mac row"),
            row("zero", "Zero", cpu: 0, memory: 0),
            row("hot", "Hot", cpu: 90, memory: 1),
        ]
        XCTAssertEqual(ids(rows.rankedByActivity()), ["hot", "zero", "old"])
    }

    /// JSON decoding refuses NaN and infinity, so no decoded snapshot can
    /// deliver them; the helper still treats a non-finite CPU as missing
    /// rather than letting NaN's unordered comparisons break the ordering.
    func testNonFiniteCPURanksAsMissing() {
        let rows = [
            row("nan", "NaN", cpu: .nan, memory: 100),
            row("inf", "Inf", cpu: .infinity, memory: 100),
            row("nil", "Nil"),
            row("real", "Real", cpu: 1, memory: 1),
        ]
        XCTAssertEqual(ids(rows.rankedByActivity()), ["real", "inf", "nan", "nil"])
    }

    /// A total order gives one answer for every permutation of its input.
    func testPermutationStability() {
        let base = [
            row("a", "A", cpu: 2, memory: 1), row("b", "B", cpu: 2, memory: 2),
            row("c", "C", cpu: 1), row("d", "D", cpu: 3), row("e", "E"),
        ]
        let want = ids(base.rankedByActivity())
        XCTAssertEqual(want, ["d", "b", "a", "c", "e"])
        var perm = base
        for i in 0..<base.count {
            perm.insert(perm.remove(at: i % perm.count), at: 0)
            XCTAssertEqual(ids(perm.rankedByActivity()), want)
        }
    }
}
