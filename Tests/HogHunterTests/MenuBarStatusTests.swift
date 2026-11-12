import AppKit
import XCTest
@testable import HogHunter

@MainActor
final class MenuBarStatusTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000)

    func testSubPercentHistoryDoesNotChangeThePicture() {
        XCTAssertEqual(picture(cpu: 10.2), picture(cpu: 10.4))
        XCTAssertNotEqual(picture(cpu: 10.2), picture(cpu: 10.6))
    }

    func testUnchangedPictureDoesNotRasterizeAgain() {
        let status = MenuBarStatus()
        status.schedulesDelayedFlush = false
        let first = bars([10], label: "10%")
        status.submit(first, now: instant)
        XCTAssertEqual(status.rasterCount, 1)
        XCTAssertEqual(status.presentation.revision, 1)
        let image = status.presentation.image

        status.submit(first, now: instant.addingTimeInterval(5))
        XCTAssertEqual(status.rasterCount, 1)
        XCTAssertEqual(status.presentation.revision, 1)
        XCTAssertTrue(status.presentation.image === image)
        assertStatusBarBitmap(image!, points: MenuBarCpuBarsView.pointSize)
    }

    func testGraphicOnlyChangesCoalesceToOneBitmapPerSecond() {
        let status = MenuBarStatus()
        status.schedulesDelayedFlush = false
        status.submit(bars([10, nil], label: "10%"), now: instant)
        let image = status.presentation.image
        let revision = status.presentation.revision
        XCTAssertEqual(status.rasterCount, 1)

        status.submit(bars([40, nil], label: "10%"), now: instant.addingTimeInterval(0.2))
        status.submit(bars([55, nil], label: "10%"), now: instant.addingTimeInterval(0.4))
        XCTAssertEqual(status.presentation.revision, revision)
        XCTAssertTrue(status.presentation.image === image)
        XCTAssertEqual(status.rasterCount, 1)

        status.flushDue(now: instant.addingTimeInterval(0.5))
        XCTAssertEqual(status.rasterCount, 1)

        status.flushDue(now: instant.addingTimeInterval(1))
        XCTAssertEqual(status.rasterCount, 2)
        XCTAssertGreaterThan(status.presentation.revision, revision)
        XCTAssertFalse(status.presentation.image === image)
    }

    func testALabelChangeInsideTheIntervalAppliesImmediately() {
        let status = MenuBarStatus()
        status.schedulesDelayedFlush = false
        status.submit(bars([10], label: "10%"), now: instant)
        let revision = status.presentation.revision

        status.submit(bars([11], label: "11%", percent: 11), now: instant.addingTimeInterval(0.2))
        XCTAssertEqual(status.presentation.label, "11%")
        XCTAssertGreaterThan(status.presentation.revision, revision)
        XCTAssertEqual(status.rasterCount, 2)
    }

    func testTextModeDoesNotAllocateABitmap() {
        let status = MenuBarStatus()
        status.schedulesDelayedFlush = false
        status.submit(bars([10], label: "10%"), now: instant)
        var text = bars([10], label: "Safari 12%")
        text.mode = .topHogName
        text.graphic = .none
        text.showIcon = true
        status.submit(text, now: instant.addingTimeInterval(0.2))
        XCTAssertEqual(status.presentation.mode, .topHogName)
        XCTAssertEqual(status.presentation.label, "Safari 12%")
        XCTAssertTrue(status.presentation.showIcon)
        XCTAssertNil(status.presentation.image)
        XCTAssertEqual(status.rasterCount, 1)
    }

    func testCalmHistoryBarsAreTemplateImages() {
        var history = CpuMinuteHistory()
        history.record(percent: 10, at: instant)
        let image = MenuBarCpuBarsView.makeImage(
            history: history,
            cpuPercent: 12,
            showPercent: true,
            at: instant
        )
        XCTAssertTrue(image.isTemplate)
        assertStatusBarBitmap(image, points: MenuBarCpuBarsView.pointSize)
    }

    func testCalmSparklineIsATemplateImage() {
        let image = CpuSparklineView.makeImage(samples: [10, 12, 8])
        XCTAssertTrue(image.isTemplate)
        assertStatusBarBitmap(image, points: CpuSparklineView.sparklinePointSize)
    }

    func testRasterizerDrawsInPointSpaceAndRejectsHugeSizes() throws {
        let image = MenuBarBitmap.rasterize(size: NSSize(width: 10, height: 10), appearance: .light) { _ in
            NSGraphicsContext.current?.shouldAntialias = false
            NSColor.red.setFill()
            NSRect(x: 0, y: 0, width: 4, height: 1).fill()
        }
        let rep = try XCTUnwrap(image.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        XCTAssertEqual(rep.pixelsWide, 20)
        XCTAssertEqual(rep.pixelsHigh, 20)
        let bottom = rep.pixelsHigh - 1
        // 4pt at 2x is 8px, origin bottom-left.  x=6 is inside, x=12 is outside.
        XCTAssertTrue(pixelHasInk(rep, x: 6, y: bottom))
        XCTAssertFalse(pixelHasInk(rep, x: 12, y: bottom))
        XCTAssertFalse(pixelHasInk(rep, x: 6, y: 0))

        let huge = MenuBarBitmap.rasterize(size: NSSize(width: 4000, height: 4000), appearance: .light) { _ in }
        XCTAssertLessThanOrEqual(huge.size.width, MenuBarBitmap.maxPointSize.width)
        XCTAssertLessThanOrEqual(huge.size.height, MenuBarBitmap.maxPointSize.height)
        let hugeRep = huge.representations.compactMap { $0 as? NSBitmapImageRep }.first
        XCTAssertLessThanOrEqual(hugeRep?.pixelsWide ?? 0, Int(MenuBarBitmap.maxPointSize.width * MenuBarBitmap.scale))
        XCTAssertLessThanOrEqual(hugeRep?.pixelsHigh ?? 0, Int(MenuBarBitmap.maxPointSize.height * MenuBarBitmap.scale))
    }

    private func pixelHasInk(_ rep: NSBitmapImageRep, x: Int, y: Int) -> Bool {
        guard let data = rep.bitmapData, x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return false }
        let bytesPerPixel = max(1, rep.bitsPerPixel / 8)
        let offset = y * rep.bytesPerRow + x * bytesPerPixel
        let limit = rep.bytesPerRow * rep.pixelsHigh
        guard offset >= 0, offset + bytesPerPixel <= limit else { return false }
        for index in 0..<bytesPerPixel where data[offset + index] != 0 {
            return true
        }
        return false
    }

    private func picture(cpu: Double) -> MenuBarPicture {
        var history = CpuMinuteHistory()
        history.record(percent: cpu, at: instant)
        let label = HogFormat.percent(cpu / 100)
        return MenuBarPicture.capture(
            mode: .historyBars,
            showIcon: false,
            showPercent: true,
            cpuPercent: cpu,
            history: history,
            samples: [cpu],
            label: label,
            help: "help",
            accessibility: label,
            at: instant,
            appearance: .light
        )
    }

    private func bars(_ values: [Int?], label: String, percent: Int = 10) -> MenuBarPicture {
        MenuBarPicture(
            mode: .historyBars,
            graphic: .historyBars(percent: percent, bars: values, showPercent: true),
            appearance: .light,
            label: label,
            showIcon: false,
            showPercent: true,
            help: "help",
            accessibility: label
        )
    }
}
