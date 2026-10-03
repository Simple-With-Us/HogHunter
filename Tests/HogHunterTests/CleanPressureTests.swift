import XCTest
@testable import HogHunter

/// Tests for the pressure rules the owner corrected on 2026-10-02.
///
/// The failure these guard against is specific and expensive: a guard whose
/// threshold sits inside the host's normal operating band silently stops the
/// work forever, while every surface still reports "running".  So most of
/// these assert that a pressured machine produces a *smaller burst* rather
/// than no burst.
final class CleanPressureTests: XCTestCase {

    // MARK: - Helpers

    private func pressure(
        diskFreeGB: Double = 100,
        swap: Double = 0,
        load1: Double = 0,
        idle: Double? = 80,
        kernel: Double? = nil
    ) -> CleanPressure {
        CleanPressure(
            diskFreeGB: diskFreeGB,
            swapUsedPercent: swap,
            load1: load1,
            cpuIdlePercent: idle,
            kernelTaskPercent: kernel
        )
    }

    private var regimen: CleanRegimen {
        var r = CleanRegimen()
        r.targetsPerChunk = 3
        r.pressuredTargetsPerChunk = 2
        r.chunkPauseSeconds = 5
        r.pressuredChunkPauseSeconds = 10
        return r
    }

    // MARK: - The core ruling: pressure shrinks the burst, never the work

    func testCalmMachineUsesConfiguredChunkSize() {
        let p = pressure(swap: 10, load1: 2, idle: 80)
        XCTAssertEqual(p.chunkSize(regimen: regimen), 3)
        XCTAssertEqual(p.pauseSeconds(regimen: regimen), 5)
        XCTAssertEqual(p.label, "Calm")
    }

    func testHighSwapStillCleansJustInSmallerChunks() {
        // This is the exact case that used to suppress the engine entirely.
        let p = pressure(swap: 93, load1: 19, idle: 24.31)
        XCTAssertGreaterThan(p.chunkSize(regimen: regimen), 0, "pressure must never produce an empty burst")
        XCTAssertEqual(p.chunkSize(regimen: regimen), 2)
        XCTAssertEqual(p.pauseSeconds(regimen: regimen), 10)
    }

    func testHighLoadAloneStillCleans() {
        let p = pressure(swap: 10, load1: 55, idle: 30)
        XCTAssertGreaterThan(p.chunkSize(regimen: regimen), 0)
        XCTAssertEqual(p.chunkSize(regimen: regimen), 2)
    }

    func testChunkSizeIsNeverZeroEvenWithHostileSettings() {
        var r = regimen
        r.targetsPerChunk = 0
        r.pressuredTargetsPerChunk = -5
        let p = pressure(swap: 95, load1: 90, idle: 1)
        XCTAssertGreaterThanOrEqual(p.chunkSize(regimen: r), 1)
    }

    // MARK: - Busy is not thrashing

    func testHighLoadWithHighIdleIsNotThrashing() {
        // Measured 2026-10-02 21:00: load1 25.68, 27% idle, kernel_task absent
        // from the top-CPU sample.  That is real fleet work.
        let p = pressure(swap: 92, load1: 25.68, idle: 27)
        XCTAssertFalse(p.isThrashing)
        XCTAssertEqual(p.label, "Elevated (Chunked)")
    }

    func testLowIdleIsThrashingRegardlessOfLoad() {
        let p = pressure(swap: 0, load1: 1, idle: 4)
        XCTAssertTrue(p.isThrashing)
        XCTAssertEqual(p.label, "Throttling")
    }

    func testIdleFloorBoundary() {
        XCTAssertFalse(pressure(idle: CleanPressure.idleFloorPercent).isThrashing)
        XCTAssertTrue(pressure(idle: CleanPressure.idleFloorPercent - 0.1).isThrashing)
    }

    func testUnknownIdleIsNotTreatedAsThrashing() {
        // A metric we could not read must never shrink the work.  Treating an
        // unknown as 0% idle would re-introduce the original bug whenever the
        // read failed.
        let p = pressure(swap: 95, load1: 50, idle: nil)
        XCTAssertFalse(p.isThrashing)
        XCTAssertGreaterThan(p.chunkSize(regimen: regimen), 0)
    }

    func testThrashingUsesSmallestBurstAndLongestPause() {
        let p = pressure(swap: 99, load1: 99, idle: 2)
        XCTAssertEqual(p.chunkSize(regimen: regimen), 1)
        XCTAssertEqual(p.pauseSeconds(regimen: regimen), 20)
    }

    // MARK: - Disk bands and the expensive tier

    func testDiskBands() {
        XCTAssertEqual(pressure(diskFreeGB: 10).diskBand, "critical")
        XCTAssertEqual(pressure(diskFreeGB: 30).diskBand, "acute")
        XCTAssertEqual(pressure(diskFreeGB: 60).diskBand, "ok")
        XCTAssertEqual(pressure(diskFreeGB: 200).diskBand, "healthy")
    }

    func testExpensiveTierNeedsSpacePressureNotBusyCpu() {
        // Busy CPU is this machine's normal state, so it must not be the lever
        // that opens an 18 GB delete.
        let busy = pressure(diskFreeGB: 200, swap: 99, load1: 120, idle: 30)
        XCTAssertFalse(busy.allowsExpensiveTier(regimen: regimen))

        let tight = pressure(diskFreeGB: 20, swap: 5, load1: 1, idle: 80)
        XCTAssertTrue(tight.allowsExpensiveTier(regimen: regimen))
    }
}
