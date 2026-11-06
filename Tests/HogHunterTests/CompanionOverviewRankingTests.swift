import XCTest
@testable import HogHunter

/// HH-212: the phone Overview's busiest ranking is a total order.  The first
/// draft used an epsilon comparator (treat |a-b| < 0.05 as a tie and fall
/// through to memory), which is not transitive: CPU 0/memory 3, CPU 0.04/
/// memory 2 and CPU 0.08/memory 1 form a cycle.  These tests pin the exact
/// total order so that shape of bug cannot come back.
final class CompanionOverviewRankingTests: XCTestCase {
    private func row(_ id: String, _ name: String, cpu: Double? = nil, memory: UInt64? = nil,
                     cpuText: String = "", memoryText: String = "") -> CompanionRow {
        CompanionRow(id: id, name: name, detail: "", cpuText: cpuText, memoryText: memoryText,
                     severity: "calm", isApp: true, cpuPercent: cpu, memoryBytes: memory)
    }

    /// Every ordering of the input (Heap's algorithm), so the stability test
    /// covers all permutations instead of a handful of rotations.
    private func allPermutations<T>(_ items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        var result: [[T]] = []
        var a = items
        func generate(_ k: Int) {
            if k == 1 { result.append(a); return }
            generate(k - 1)
            for i in 0..<(k - 1) {
                if k % 2 == 0 { a.swapAt(i, k - 1) } else { a.swapAt(0, k - 1) }
                generate(k - 1)
            }
        }
        generate(a.count)
        return result
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

    /// Rows from a Mac too old to send numeric fields still rank by the
    /// text readings it sent (the same fallback `sortCPU`/`sortMemory`
    /// use), instead of dropping to name order.  A row with no reading at
    /// all still ranks last.
    func testTextFallbackRanksOlderMacRows() {
        let rows = [
            row("text-mid", "Text Mid", cpuText: "12%", memoryText: "1 GB"),
            row("text-high", "Text High", cpuText: "80%", memoryText: "512 MB"),
            row("numbered", "Numbered", cpu: 50, memory: 1),
            row("empty", "Empty"),
        ]
        XCTAssertEqual(ids(rows.rankedByActivity()), ["text-high", "numbered", "text-mid", "empty"])
    }

    /// Display text is untrusted: a reading that scales to or beyond 2^64
    /// must not trap the ranking; it counts as no reading instead.
    func testOutOfRangeMemoryTextDoesNotTrap() {
        let rows = [
            row("huge", "Huge", cpu: 1, memoryText: "16777216 TB"),
            row("overflow", "Overflow", cpu: 1, memoryText: "99999999999999999999999 TB"),
            row("small", "Small", cpu: 1, memory: 5),
        ]
        XCTAssertEqual(ids(rows.rankedByActivity()), ["small", "huge", "overflow"])
    }

    /// Two spellings Swift keeps distinct (the combining acute sits on f in
    /// one and inside \u{00E9} in the other, so the pair is not canonically
    /// equivalent) must not confuse the ranking: whether the collation folds
    /// the accent difference to `.orderedSame` or orders the plain f first,
    /// a-row sorts before b-row, and a folded pair still needs the id
    /// tiebreaker, or two different rows compare equal both ways.
    func testCollationEquivalentNamesBreakTieOnID() {
        let rows = [
            row("b-row", "Caf\u{0301}e", cpu: 1),
            row("a-row", "Caf\u{00E9}", cpu: 1),
        ]
        for permutation in allPermutations(rows) {
            XCTAssertEqual(ids(permutation.rankedByActivity()), ["a-row", "b-row"])
        }
        // A case-only difference looked like the surest `.orderedSame`
        // coverage, but the assumption is false: the Finder-style collation
        // applies forced ordering and decides even case-only differences
        // ("casesame" vs "CaseSame" is .orderedAscending, measured on macOS
        // CI run 42178487100), so `.orderedSame` has no reachable test input
        // through localizedStandardCompare and the id tie-break behind it is
        // defensive.  What can be pinned is the behavior the tie-break
        // protects: distinct names, however close, order deterministically
        // under every input permutation.
        let caseRows = [
            row("c-row", "casesame", cpu: 1),
            row("d-row", "CaseSame", cpu: 1),
        ]
        for permutation in allPermutations(caseRows) {
            XCTAssertEqual(ids(permutation.rankedByActivity()), ["c-row", "d-row"])
        }
    }

    /// A total order gives one answer for every permutation of its input.
    /// Enumerating all 120 permutations of the five rows pins the
    /// transitivity the Overview ranking depends on; five rotations cannot
    /// catch a comparator that only agrees on rotations.
    func testPermutationStability() {
        let base = [
            row("a", "A", cpu: 2, memory: 1), row("b", "B", cpu: 2, memory: 2),
            row("c", "C", cpu: 1), row("d", "D", cpu: 3), row("e", "E"),
        ]
        let want = ids(base.rankedByActivity())
        XCTAssertEqual(want, ["d", "b", "a", "c", "e"])
        let permutations = allPermutations(base)
        XCTAssertEqual(permutations.count, 120)
        for perm in permutations {
            XCTAssertEqual(ids(perm.rankedByActivity()), want)
        }
    }
}
