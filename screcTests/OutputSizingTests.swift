import XCTest

final class OutputSizingTests: XCTestCase {
    private func size(_ w: CGFloat, _ h: CGFloat, scale: CGFloat = 2,
                      maxW: Int? = nil, maxH: Int? = nil) -> (Int, Int) {
        OutputSizing.pixelSize(contentPoints: CGSize(width: w, height: h),
                               scale: scale, maxWidth: maxW, maxHeight: maxH)
    }

    func testNativeWhenUncapped() {
        XCTAssertEqual(size(800, 600).0, 1600)
        XCTAssertEqual(size(800, 600).1, 1200)
    }

    func testCapShrinksPreservingAspect() {
        let (w, h) = size(800, 600, maxW: 1280, maxH: 1280)
        XCTAssertEqual(w, 1280)
        XCTAssertEqual(h, 960)
    }

    func testCapNeverUpscales() {
        let (w, h) = size(400, 300, maxW: 1280, maxH: 1280)
        XCTAssertEqual(w, 800)
        XCTAssertEqual(h, 600)
    }

    func testTighterOfTwoCapsWins() {
        // 2000×1000 px native; width cap 1000 (factor 0.5) vs height cap 800
        // (factor 0.8) — the smaller factor applies to both axes.
        let (w, h) = size(1000, 500, maxW: 1000, maxH: 800)
        XCTAssertEqual(w, 1000)
        XCTAssertEqual(h, 500)
        let (w2, h2) = size(1000, 500, maxW: 800, maxH: 1000)
        XCTAssertEqual(w2, 800)
        XCTAssertEqual(h2, 400)
    }

    func testOddDimensionsRoundDownToEven() {
        let (w, h) = size(401, 301, scale: 1)
        XCTAssertEqual(w, 400)
        XCTAssertEqual(h, 300)
    }

    func testMinimumTwoPixels() {
        let (w, h) = size(0.4, 0.4, scale: 1)
        XCTAssertEqual(w, 2)
        XCTAssertEqual(h, 2)
    }

    func testZeroOrNegativeCapMeansUncapped() {
        let (w, h) = size(800, 600, maxW: 0, maxH: -5)
        XCTAssertEqual(w, 1600)
        XCTAssertEqual(h, 1200)
    }
}
