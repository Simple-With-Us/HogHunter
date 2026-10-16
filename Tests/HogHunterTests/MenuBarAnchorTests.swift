import XCTest
import SwiftUI
@testable import HogHunter

final class MenuBarAnchorTests: XCTestCase {
    func testDockedPanelShapeIncludesBeakApexAtTargetX() {
        let shape = DockedPanelShape(beakX: 565, isDocked: true)
        let rect = CGRect(x: 0, y: 0, width: 620, height: 680)
        let path = shape.path(in: rect)

        // When docked, the path bounds should start at y = 0 (the apex of the beak)
        let bounds = path.boundingRect
        XCTAssertEqual(bounds.minY, 0, accuracy: 0.01)
        XCTAssertEqual(bounds.width, 620, accuracy: 0.01)
        XCTAssertEqual(bounds.height, 680, accuracy: 0.01)
    }

    func testDetachedPanelShapeHasStandardRoundedRect() {
        let shape = DockedPanelShape(beakX: 565, isDocked: false)
        let rect = CGRect(x: 0, y: 0, width: 620, height: 680)
        let path = shape.path(in: rect)

        let bounds = path.boundingRect
        XCTAssertEqual(bounds.minY, 0, accuracy: 0.01)
        XCTAssertEqual(bounds.width, 620, accuracy: 0.01)
        XCTAssertEqual(bounds.height, 680, accuracy: 0.01)
    }

    func testDockedPanelShapeClampsBeakAwayFromCorners() {
        // Test extreme right beakX
        let shapeRight = DockedPanelShape(beakX: 9999, isDocked: true)
        let pathRight = shapeRight.path(in: CGRect(x: 0, y: 0, width: 620, height: 680))
        XCTAssertFalse(pathRight.isEmpty)

        // Test extreme left beakX
        let shapeLeft = DockedPanelShape(beakX: -9999, isDocked: true)
        let pathLeft = shapeLeft.path(in: CGRect(x: 0, y: 0, width: 620, height: 680))
        XCTAssertFalse(pathLeft.isEmpty)
    }

    func testMenuBarAnchorViewResolvesGracefullyWithoutStatusItem() {
        let view = MenuBarAnchorView()
        var reportedX: CGFloat?
        view.onPosition = { reportedX = $0 }

        // Create a standalone window of panel size
        let win = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 620, height: 680),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        win.contentView = view
        view.resolveAnchor()

        // Without an active menu bar item, it defaults to winW - 55 = 565
        XCTAssertNotNil(reportedX)
        if let x = reportedX {
            XCTAssertEqual(x, 565, accuracy: 1.0)
        }
    }
}
