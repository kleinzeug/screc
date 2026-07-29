import XCTest

final class GIFTimingTests: XCTestCase {
    func testGridSnapsToTimelineNotKeptFrames() {
        let step = 1.0 / 12.0
        // After a frame at t=0 the next slot is one step in.
        XCTAssertEqual(GIFTiming.nextGridTime(after: 0, step: step), step,
                       accuracy: 1e-9)
        // A sparse frame at t=1.0 (idle heartbeat) must snap the grid to the
        // timeline slot after 1.0 — not to "previous + step".
        XCTAssertEqual(GIFTiming.nextGridTime(after: 1.0, step: step),
                       13.0 / 12.0, accuracy: 1e-9)
    }

    func testQuantizerCarryPreventsDrift() {
        // 5 s at 12 fps: naive per-frame rounding to centiseconds would lose
        // 0.0033 s per frame (~0.2 s here). The carry keeps the sum honest.
        var quantizer = GIFDelayQuantizer()
        let step = 1.0 / 12.0
        let total = (0..<60).reduce(0.0) { sum, _ in sum + quantizer.quantize(step) }
        XCTAssertEqual(total, 5.0, accuracy: 0.011)
    }

    func testQuantizerFloorsTinyDelays() {
        var quantizer = GIFDelayQuantizer()
        XCTAssertEqual(quantizer.quantize(0.001), 0.02)
    }

    func testLongIdleGapPassesThrough() {
        var quantizer = GIFDelayQuantizer()
        XCTAssertEqual(quantizer.quantize(4.0), 4.0, accuracy: 0.005)
    }

    func testNegativeInputClampsToMinimum() {
        var quantizer = GIFDelayQuantizer()
        XCTAssertEqual(quantizer.quantize(-1.0), 0.02)
    }
}
