import CoreGraphics

/// Output-resolution math, extracted for testability (compiled into both the
/// app and the hermetic unit-test bundle).
enum OutputSizing {
    /// Native pixels capped to max width/height (caps only shrink, never
    /// upscale; aspect preserved), rounded to even dimensions (H.264 dislikes
    /// odd sizes).
    static func pixelSize(contentPoints: CGSize, scale: CGFloat,
                          maxWidth: Int?, maxHeight: Int?) -> (Int, Int) {
        var width = max(contentPoints.width * scale, 2)
        var height = max(contentPoints.height * scale, 2)
        var factor: CGFloat = 1
        if let cap = maxWidth.map(CGFloat.init), cap > 0, width > cap {
            factor = min(factor, cap / width)
        }
        if let cap = maxHeight.map(CGFloat.init), cap > 0, height > cap {
            factor = min(factor, cap / height)
        }
        width *= factor
        height *= factor
        return (max(2, Int(width.rounded()) & ~1),
                max(2, Int(height.rounded()) & ~1))
    }
}
