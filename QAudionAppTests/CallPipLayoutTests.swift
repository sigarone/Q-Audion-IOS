import XCTest
@testable import QAudionApp

/// The local camera preview of the video call: free area between header and dock, snapping to the nearest corner.
final class CallPipLayoutTests: XCTestCase {

    private let screen = CGSize(width: 390, height: 844)

    func testFreeAreaStaysBetweenHeaderAndDock() {
        let area = CallPipLayout.freeArea(size: screen, topInset: 120, bottomInset: 200)
        XCTAssertEqual(area.minY, 128)
        XCTAssertEqual(area.maxY, 636)
        XCTAssertEqual(area.minX, 16)
        XCTAssertEqual(area.maxX, 374)
    }

    func testHiddenDockFreesTheBottom() {
        let withDock = CallPipLayout.freeArea(size: screen, topInset: 120, bottomInset: 200)
        let withoutDock = CallPipLayout.freeArea(size: screen, topInset: 120, bottomInset: 34)
        XCTAssertGreaterThan(withoutDock.maxY, withDock.maxY)
    }

    func testDegenerateAreaNeverHasNegativeSize() {
        let area = CallPipLayout.freeArea(size: CGSize(width: 100, height: 300), topInset: 250, bottomInset: 250)
        XCTAssertGreaterThanOrEqual(area.width, 0)
        XCTAssertGreaterThanOrEqual(area.height, 0)
    }

    func testNearestCornerIsTheQuadrantOfThePoint() {
        let bounds = CGRect(x: 16, y: 128, width: 358, height: 508)
        XCTAssertEqual(CallPipLayout.nearestCorner(point: CGPoint(x: 40, y: 150), bounds: bounds), .topLeading)
        XCTAssertEqual(CallPipLayout.nearestCorner(point: CGPoint(x: 350, y: 150), bounds: bounds), .topTrailing)
        XCTAssertEqual(CallPipLayout.nearestCorner(point: CGPoint(x: 40, y: 600), bounds: bounds), .bottomLeading)
        XCTAssertEqual(CallPipLayout.nearestCorner(point: CGPoint(x: 350, y: 600), bounds: bounds), .bottomTrailing)
        XCTAssertEqual(CallPipLayout.nearestCorner(point: CGPoint(x: bounds.midX, y: bounds.midY), bounds: bounds), .topTrailing)
    }

    func testOriginsSitInTheCornersOfTheArea() {
        let area = CGRect(x: 16, y: 128, width: 358, height: 508)
        let size = CallPipLayout.size
        XCTAssertEqual(CallPipLayout.origin(corner: .topLeading, area: area), CGPoint(x: 16, y: 128))
        XCTAssertEqual(CallPipLayout.origin(corner: .topTrailing, area: area), CGPoint(x: 374 - size.width, y: 128))
        XCTAssertEqual(CallPipLayout.origin(corner: .bottomLeading, area: area), CGPoint(x: 16, y: 636 - size.height))
        XCTAssertEqual(CallPipLayout.origin(corner: .bottomTrailing, area: area),
                       CGPoint(x: 374 - size.width, y: 636 - size.height))
    }

    func testSasPanelLiftsOnlyTheBottomLeadingCorner() {
        let area = CGRect(x: 16, y: 128, width: 358, height: 508)
        let size = CallPipLayout.size
        XCTAssertEqual(CallPipLayout.origin(corner: .bottomLeading, area: area, leadingBottomLimit: 500).y, 500 - size.height)
        XCTAssertEqual(CallPipLayout.origin(corner: .bottomTrailing, area: area, leadingBottomLimit: 500).y, 636 - size.height)
    }

    func testDefaultIsTopTrailingAndClampKeepsThePreviewInside() {
        XCTAssertEqual(CallPipLayout.defaultCorner, .topTrailing)
        let rect = CGRect(x: 0, y: 47, width: 390, height: 763)
        let size = CallPipLayout.size
        XCTAssertEqual(CallPipLayout.clamped(origin: CGPoint(x: -50, y: -50), within: rect), CGPoint(x: 0, y: 47))
        XCTAssertEqual(CallPipLayout.clamped(origin: CGPoint(x: 900, y: 900), within: rect),
                       CGPoint(x: 390 - size.width, y: 810 - size.height))
    }
}
