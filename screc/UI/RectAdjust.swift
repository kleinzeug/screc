import AppKit

/// Shared interactive-rect drag logic for the region picker and the window
/// sub-region picker:
///  - edge drag moves that edge, corner drag moves that corner
///  - inside drag moves the whole rect
///  - ⌥ mirrors the change to the opposing edge/corner (around the center)
///  - ⇧ constrains to the aspect ratio at drag start
///  - ⌥⇧ combines both
struct RectDrag {
    enum Mode: Equatable {
        case move
        /// -1 = min edge, 1 = max edge, 0 = untouched axis.
        case resize(ex: Int, ey: Int)
    }

    let mode: Mode
    let startRect: NSRect
    let startPoint: NSPoint

    static func hitTest(point: NSPoint, rect: NSRect, margin: CGFloat = 8) -> Mode? {
        guard rect.insetBy(dx: -margin, dy: -margin).contains(point) else { return nil }
        let nearLeft = abs(point.x - rect.minX) <= margin
        let nearRight = abs(point.x - rect.maxX) <= margin
        let nearBottom = abs(point.y - rect.minY) <= margin
        let nearTop = abs(point.y - rect.maxY) <= margin
        let ex = nearLeft ? -1 : (nearRight ? 1 : 0)
        let ey = nearBottom ? -1 : (nearTop ? 1 : 0)
        if ex != 0 || ey != 0 { return .resize(ex: ex, ey: ey) }
        return rect.contains(point) ? .move : nil
    }

    func rect(at point: NSPoint, modifiers: NSEvent.ModifierFlags,
              bounds: NSRect, minSize: CGFloat = 24) -> NSRect {
        let dx = point.x - startPoint.x
        let dy = point.y - startPoint.y
        switch mode {
        case .move:
            var r = startRect.offsetBy(dx: dx, dy: dy)
            r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
            r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
            return r
        case .resize(let ex, let ey):
            return Self.resized(start: startRect, ex: ex, ey: ey, dx: dx, dy: dy,
                                mirror: modifiers.contains(.option),
                                keepAspect: modifiers.contains(.shift),
                                bounds: bounds, minSize: minSize)
        }
    }

    private static func resized(start: NSRect, ex: Int, ey: Int,
                                dx: CGFloat, dy: CGFloat,
                                mirror: Bool, keepAspect: Bool,
                                bounds: NSRect, minSize: CGFloat) -> NSRect {
        var minX = start.minX, maxX = start.maxX
        var minY = start.minY, maxY = start.maxY
        if ex == -1 { minX += dx; if mirror { maxX -= dx } }
        if ex == 1 { maxX += dx; if mirror { minX -= dx } }
        if ey == -1 { minY += dy; if mirror { maxY -= dy } }
        if ey == 1 { maxY += dy; if mirror { minY -= dy } }
        var width = max(maxX - minX, minSize)
        var height = max(maxY - minY, minSize)

        if keepAspect, start.width > 0, start.height > 0 {
            let aspect = start.width / start.height
            if ex != 0 && ey != 0 {
                // Corner: the dominant relative change wins.
                if width / start.width >= height / start.height {
                    height = width / aspect
                } else {
                    width = height * aspect
                }
            } else if ex != 0 {
                height = width / aspect
            } else {
                width = height * aspect
            }
        }

        var r = NSRect(x: minX, y: minY, width: width, height: height)
        if mirror {
            r.origin.x = start.midX - width / 2
            r.origin.y = start.midY - height / 2
        } else {
            // Anchor the opposite edge on resized axes; center on the
            // perpendicular axis when the aspect lock forces it to change.
            if ex == -1 { r.origin.x = start.maxX - width }
            else if ex == 1 { r.origin.x = start.minX }
            else { r.origin.x = keepAspect ? start.midX - width / 2 : start.minX }
            if ey == -1 { r.origin.y = start.maxY - height }
            else if ey == 1 { r.origin.y = start.minY }
            else { r.origin.y = keepAspect ? start.midY - height / 2 : start.minY }
        }

        // Clamp into bounds; with the aspect lock, shrink uniformly instead
        // of distorting.
        if keepAspect {
            let fit = min(1, bounds.width / r.width, bounds.height / r.height)
            if fit < 1 {
                let cw = r.width * fit, ch = r.height * fit
                if mirror {
                    r = NSRect(x: start.midX - cw / 2, y: start.midY - ch / 2,
                               width: cw, height: ch)
                } else {
                    if ex == -1 { r.origin.x = r.maxX - cw }
                    if ey == -1 { r.origin.y = r.maxY - ch }
                    r.size = NSSize(width: cw, height: ch)
                }
            }
        } else {
            r.size.width = min(r.width, bounds.width)
            r.size.height = min(r.height, bounds.height)
        }
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }
}

/// Shared drawing for the adjustable-rect UI: resize handles, the centered
/// "W × H" label, and the dragged-element coordinate chip at the mouse.
/// Coordinates are shown top-left-origin relative to a container (screen or
/// window), the way users think about screen positions.
@MainActor
enum AdjustChrome {
    static func drawHandles(for rect: NSRect) {
        let positions = [
            NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.midX, y: rect.minY),
            NSPoint(x: rect.maxX, y: rect.minY), NSPoint(x: rect.minX, y: rect.midY),
            NSPoint(x: rect.maxX, y: rect.midY), NSPoint(x: rect.minX, y: rect.maxY),
            NSPoint(x: rect.midX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.maxY),
        ]
        for p in positions {
            let handle = NSRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: handle).fill()
            NSColor.black.withAlphaComponent(0.4).setStroke()
            NSBezierPath(ovalIn: handle).stroke()
        }
    }

    static func drawSizeLabel(centeredIn rect: NSRect) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))"
        let size = text.size(withAttributes: chipAttributes)
        drawChip(text, at: NSPoint(x: rect.midX - size.width / 2,
                                   y: rect.midY - size.height / 2))
    }

    static func drawCoordChip(mode: RectDrag.Mode, rect: NSRect,
                              container: NSRect, mouse: NSPoint,
                              viewBounds: NSRect) {
        let text = coordText(mode: mode, rect: rect, container: container)
        let size = text.size(withAttributes: chipAttributes)
        var origin = NSPoint(x: mouse.x + 14, y: mouse.y + 14)
        origin.x = min(max(origin.x, viewBounds.minX + 4),
                       viewBounds.maxX - size.width - 10)
        origin.y = min(max(origin.y, viewBounds.minY + 4),
                       viewBounds.maxY - size.height - 8)
        drawChip(text, at: origin)
    }

    private static func coordText(mode: RectDrag.Mode, rect: NSRect,
                                  container: NSRect) -> String {
        func localX(_ x: CGFloat) -> Int { Int((x - container.minX).rounded()) }
        func topLeftY(_ y: CGFloat) -> Int { Int((container.maxY - y).rounded()) }
        switch mode {
        case .move:
            return "(\(localX(rect.minX)), \(topLeftY(rect.maxY)))"
        case .resize(let ex, let ey):
            let px = ex == -1 ? rect.minX : rect.maxX
            let py = ey == -1 ? rect.minY : rect.maxY
            if ex != 0 && ey != 0 { return "(\(localX(px)), \(topLeftY(py)))" }
            if ex != 0 { return "x: \(localX(px))" }
            return "y: \(topLeftY(py))"
        }
    }

    private static let chipAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.white,
    ]

    private static func drawChip(_ text: String, at origin: NSPoint) {
        let size = text.size(withAttributes: chipAttributes)
        let background = NSRect(x: origin.x - 6, y: origin.y - 3,
                                width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: background, xRadius: 4, yRadius: 4).fill()
        text.draw(at: origin, withAttributes: chipAttributes)
    }
}
