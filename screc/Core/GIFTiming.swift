import Foundation

/// GIF frame-timing math, extracted for testability (compiled into both the
/// app and the hermetic unit-test bundle).
enum GIFTiming {
    /// Next sampling-grid time strictly after `pts`. Snapped to the SOURCE
    /// timeline — never advanced per kept frame — so sparse (idle-heartbeat)
    /// sources cannot drag the grid along and time-compress the output.
    static func nextGridTime(after pts: Double, step: Double) -> Double {
        (floor(pts / step) + 1) * step
    }
}

/// GIF stores frame delays in centiseconds. Rounding each delay separately
/// would drift (12 fps → 0.0833 s stored as 0.08 s plays ~4 % fast); this
/// quantizer carries the rounding remainder into the next frame instead.
/// Delays are floored at 0.02 s — players clamp anything below to 0.1 s.
struct GIFDelayQuantizer {
    private(set) var carry = 0.0

    mutating func quantize(_ seconds: Double) -> Double {
        let target = max(seconds, 0) + carry
        let centiseconds = max(2, Int((target * 100).rounded()))
        let delay = Double(centiseconds) / 100
        carry = target - delay
        return delay
    }
}
