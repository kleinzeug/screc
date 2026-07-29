import XCTest

final class RectDragTests: XCTestCase {
    private let rect = NSRect(x: 100, y: 100, width: 200, height: 100)
    private let bounds = NSRect(x: 0, y: 0, width: 1000, height: 1000)

    // MARK: hitTest

    func testHitTestCorner() {
        XCTAssertEqual(RectDrag.hitTest(point: NSPoint(x: 100, y: 100), rect: rect),
                       .resize(ex: -1, ey: -1))
        XCTAssertEqual(RectDrag.hitTest(point: NSPoint(x: 300, y: 200), rect: rect),
                       .resize(ex: 1, ey: 1))
    }

    func testHitTestEdge() {
        XCTAssertEqual(RectDrag.hitTest(point: NSPoint(x: 300, y: 150), rect: rect),
                       .resize(ex: 1, ey: 0))
        XCTAssertEqual(RectDrag.hitTest(point: NSPoint(x: 200, y: 100), rect: rect),
                       .resize(ex: 0, ey: -1))
    }

    func testHitTestInsideMoves() {
        XCTAssertEqual(RectDrag.hitTest(point: NSPoint(x: 200, y: 150), rect: rect), .move)
    }

    func testHitTestOutsideMarginIsNil() {
        XCTAssertNil(RectDrag.hitTest(point: NSPoint(x: 90, y: 90), rect: rect))
    }

    // MARK: dragging

    private func drag(_ mode: RectDrag.Mode, from start: NSPoint, to point: NSPoint,
                      modifiers: NSEvent.ModifierFlags = []) -> NSRect {
        RectDrag(mode: mode, startRect: rect, startPoint: start)
            .rect(at: point, modifiers: modifiers, bounds: bounds)
    }

    func testEdgeDragMovesThatEdge() {
        let result = drag(.resize(ex: 1, ey: 0),
                          from: NSPoint(x: 300, y: 150), to: NSPoint(x: 350, y: 150))
        XCTAssertEqual(result, NSRect(x: 100, y: 100, width: 250, height: 100))
    }

    func testMirrorResizesAroundCenter() {
        let result = drag(.resize(ex: 1, ey: 0),
                          from: NSPoint(x: 300, y: 150), to: NSPoint(x: 350, y: 150),
                          modifiers: .option)
        XCTAssertEqual(result, NSRect(x: 50, y: 100, width: 300, height: 100))
    }

    func testAspectLockCornerDominantAxisWins() {
        let result = drag(.resize(ex: 1, ey: 1),
                          from: NSPoint(x: 300, y: 200), to: NSPoint(x: 400, y: 220),
                          modifiers: .shift)
        // Width grew 1.5×, height only 1.2× — width wins, height follows 2:1.
        XCTAssertEqual(result, NSRect(x: 100, y: 100, width: 300, height: 150))
    }

    func testMinSizeAnchorsOppositeEdge() {
        let result = drag(.resize(ex: -1, ey: 0),
                          from: NSPoint(x: 100, y: 150), to: NSPoint(x: 350, y: 150))
        XCTAssertEqual(result.width, 24)
        XCTAssertEqual(result.maxX, 300, accuracy: 0.001)
    }

    func testMoveClampsToBounds() {
        let result = drag(.move, from: NSPoint(x: 200, y: 150),
                          to: NSPoint(x: -500, y: 150))
        XCTAssertEqual(result.minX, 0)
        XCTAssertEqual(result.width, 200)
    }
}
