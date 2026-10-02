import XCTest

@testable import HogHunter

/// Covers the bandwidth half of the Network tab: turning cumulative interface
/// counters into a rate, and reading a 24-hour peak back out of the history
/// database.  The counters themselves come from `getifaddrs`, so what is
/// tested here is the arithmetic that turns them into something a person can
/// read -- not the kernel.
final class BandwidthTests: XCTestCase {

    // MARK: - BandwidthTracker

    private func counters(download: UInt64, upload: UInt64) -> InterfaceCounters {
        InterfaceCounters(received: download, sent: upload)
    }

    /// One difference between two readings is the whole rate: bytes moved over
    /// the seconds between them.
    func testRateIsTheDifferenceOverTheElapsedSeconds() {
        var tracker = BandwidthTracker()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        tracker.ingest(counters(download: 1_000, upload: 100), at: start)
        let reading = tracker.ingest(counters(download: 51_000, upload: 1_100), at: start.addingTimeInterval(10))

        XCTAssertTrue(reading.isMeasured)
        XCTAssertEqual(reading.downBytesPerSecond, 5_000, accuracy: 0.5)
        XCTAssertEqual(reading.upBytesPerSecond, 100, accuracy: 0.5)
        XCTAssertEqual(reading.windowSeconds, 10, accuracy: 0.001)
    }

    /// The first reading establishes a baseline; there is nothing to
    /// difference it against, so the panel must read "Measuring…" rather than
    /// a confident zero.
    func testFirstReadingIsNotAMeasurement() {
        var tracker = BandwidthTracker()
        let reading = tracker.ingest(counters(download: 900, upload: 900), at: Date())
        XCTAssertFalse(reading.isMeasured)
    }

    /// A counter that went backwards means an interface was re-created, not
    /// that traffic reversed.  Differencing across it would print a negative
    /// spike, so the ring restarts and reports nothing until a real pair exists.
    func testCounterResetRestartsTheWindowInsteadOfGoingNegative() {
        var tracker = BandwidthTracker()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        tracker.ingest(counters(download: 1_000_000, upload: 1_000_000), at: start)
        tracker.ingest(counters(download: 1_100_000, upload: 1_100_000), at: start.addingTimeInterval(5))

        // Wi-Fi reconnects: the counters are reset to near zero.
        let afterReset = tracker.ingest(counters(download: 12, upload: 4), at: start.addingTimeInterval(10))
        XCTAssertFalse(afterReset.isMeasured)

        // ...and the pair after the reset measures normally.
        let recovered = tracker.ingest(counters(download: 5_012, upload: 2_004), at: start.addingTimeInterval(15))
        XCTAssertTrue(recovered.isMeasured)
        XCTAssertEqual(recovered.downBytesPerSecond, 1_000, accuracy: 0.5)
        XCTAssertEqual(recovered.upBytesPerSecond, 400, accuracy: 0.5)
    }

    /// Two readings a few hundred milliseconds apart differencing a counter
    /// that ticks in gigabytes per second is rounding error, so a window under
    /// a second reports nothing at all.
    func testSubSecondWindowIsNotAMeasurement() {
        var tracker = BandwidthTracker()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        tracker.ingest(counters(download: 0, upload: 0), at: start)
        let reading = tracker.ingest(counters(download: 4_000_000, upload: 0), at: start.addingTimeInterval(0.2))
        XCTAssertFalse(reading.isMeasured)
    }

    /// The reported rate is an average over the retained window, not just the
    /// last two samples: a burst followed by quiet must not read as a
    /// permanent spike.
    func testRateAveragesTheRetainedWindowRatherThanTheLastPair() {
        var tracker = BandwidthTracker()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        tracker.ingest(counters(download: 0, upload: 0), at: start)
        // 1 MB in one second, then nothing for four.
        tracker.ingest(counters(download: 1_000_000, upload: 0), at: start.addingTimeInterval(1))
        let reading = tracker.ingest(counters(download: 1_000_000, upload: 0), at: start.addingTimeInterval(5))
        XCTAssertEqual(reading.downBytesPerSecond, 200_000, accuracy: 1)
    }

    /// The window is bounded: an hour of samples must not accumulate into a
    /// peak that averages over an hour.
    func testWindowIsBoundedToTheRecentReadings() {
        var tracker = BandwidthTracker()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for step in 0...120 {
            tracker.ingest(
                counters(download: UInt64(step) * 1_000, upload: 0),
                at: start.addingTimeInterval(Double(step) * 5)
            )
        }
        // 6 readings x 5 s = 25 s window over 5 x 1000 bytes = 200 B/s.
        XCTAssertEqual(tracker.reading.downBytesPerSecond, 200, accuracy: 1)
        XCTAssertLessThanOrEqual(tracker.reading.windowSeconds, 26)
    }

    // MARK: - History persistence

    /// A minute boundary, so each reading below lands in its own bucket no
    /// matter how the test is read.
    private let base = Date(timeIntervalSince1970: 1_700_000_040)

    func testPeakIsTheFastestSustainedRateInTheWindow() {
        let history = HistoryStore(inMemory: true)
        history.recordNetwork(bytesIn: 1_000, bytesOut: 500, at: base)
        history.recordNetwork(bytesIn: 61_000, bytesOut: 1_100, at: base.addingTimeInterval(60))
        history.recordNetwork(bytesIn: 121_000, bytesOut: 1_700, at: base.addingTimeInterval(120))

        let peaks = history.networkPeaks(lookback: 24 * 60 * 60, now: base.addingTimeInterval(180))
        XCTAssertTrue(peaks.hasSamples)
        XCTAssertEqual(peaks.peakDownBytesPerSecond, 1_000, accuracy: 0.5)
        XCTAssertEqual(peaks.peakUpBytesPerSecond, 10, accuracy: 0.5)
        XCTAssertEqual(peaks.totalDownBytes, 120_000)
        XCTAssertEqual(peaks.totalUpBytes, 1_200)
        // The high-water mark is the first minute, not the last.
        XCTAssertEqual(peaks.peakAt?.timeIntervalSince1970 ?? 0, base.timeIntervalSince1970 + 60, accuracy: 0.5)
    }

    /// A sampling gap must divide by the gap's real length.  Assuming one tick
    /// would print a five-minute silence as five minutes of full speed.
    func testGapIsDividedByItsRealLengthNotAnAssumedTick() {
        let history = HistoryStore(inMemory: true)
        history.recordNetwork(bytesIn: 0, bytesOut: 0, at: base)
        history.recordNetwork(bytesIn: 300_000, bytesOut: 0, at: base.addingTimeInterval(300))

        let peaks = history.networkPeaks(lookback: 24 * 60 * 60, now: base.addingTimeInterval(360))
        XCTAssertEqual(peaks.peakDownBytesPerSecond, 1_000, accuracy: 0.5)
    }

    /// Counter resets survive a restart: the sample before and after a re-created
    /// interface must not be differenced into a negative rate.
    func testCounterResetInHistoryDoesNotProduceANegativeRate() {
        let history = HistoryStore(inMemory: true)
        history.recordNetwork(bytesIn: 9_000_000, bytesOut: 0, at: base)
        history.recordNetwork(bytesIn: 50, bytesOut: 0, at: base.addingTimeInterval(60))
        history.recordNetwork(bytesIn: 60_050, bytesOut: 0, at: base.addingTimeInterval(120))

        let peaks = history.networkPeaks(lookback: 24 * 60 * 60, now: base.addingTimeInterval(180))
        XCTAssertEqual(peaks.peakDownBytesPerSecond, 1_000, accuracy: 0.5)
    }

    /// Two readings inside one second collapse onto one row rather than
    /// stacking, the same rule `ticks` follows.
    func testTwoReadingsInOneSecondDoNotStack() {
        let history = HistoryStore(inMemory: true)
        history.recordNetwork(bytesIn: 100, bytesOut: 100, at: base)
        history.recordNetwork(bytesIn: 200, bytesOut: 200, at: base.addingTimeInterval(0.4))

        let latest = history.latestNetworkSample()
        XCTAssertEqual(latest?.bytesIn, 200)
        XCTAssertEqual(latest?.bytesOut, 200)
    }

    func testEmptyHistoryReportsNoPeaks() {
        let history = HistoryStore(inMemory: true)
        let peaks = history.networkPeaks(lookback: 24 * 60 * 60, now: base)
        XCTAssertFalse(peaks.hasSamples)
        XCTAssertEqual(peaks.peakDownBytesPerSecond, 0)
        XCTAssertNil(history.latestNetworkSample())
    }

    /// Only the last 24 hours counts as "24-hour peak".  A day-old spike must
    /// fall out of the window rather than sit on the card forever.
    func testPeaksIgnoreSamplesOlderThanTheLookback() {
        let history = HistoryStore(inMemory: true)
        history.recordNetwork(bytesIn: 0, bytesOut: 0, at: base)
        history.recordNetwork(bytesIn: 600_000, bytesOut: 0, at: base.addingTimeInterval(60))

        let later = base.addingTimeInterval(25 * 60 * 60)
        let peaks = history.networkPeaks(lookback: 24 * 60 * 60, now: later)
        XCTAssertFalse(peaks.hasSamples)
    }

    // MARK: - Copy

    /// The machine-wide scale names the core count it divides by, because that
    /// count is the entire reason to pick it.  The stored raw value stays put
    /// so nobody's saved setting is silently reset by the rename.
    func testMachineScaleLabelCarriesTheCoreCountAndKeepsItsStoredName() {
        XCTAssertEqual(CpuScale.machineShare.displayLabel(coreCount: 10), "Per Machine (10 Cores)")
        XCTAssertEqual(CpuScale.perCore.displayLabel(coreCount: 10), "Per Core")
        XCTAssertEqual(CpuScale.machineShare.rawValue, "Share of Machine")
    }
}
