import AppKit

// Purpose-drawn app-icon slots for the small sizes (16pt and 32pt). A
// downscaled version of the full icon turns to mush at 16 px, so these are
// drawn as the menu-bar badge instead: a red dot with "REC" beside it on a
// translucent dark rounded rect. "REC" is dropped below the size where it
// would stop being legible and the dot is centred alone — at 16 px a
// three-letter word is roughly four pixels tall, which reads as dirt.
//
//   swiftc -O tools/smallicons.swift -o /tmp/smallicons && /tmp/smallicons <outdir>
@main struct SmallIcons {
    /// px: pixel size of the slot. Text is only drawn when it can be legible.
    static func badge(px: Int, withText: Bool) -> NSImage {
        let side = CGFloat(px)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            // #FF453A — sampled from the full icon, which is macOS systemRed.
            let red = NSColor(srgbRed: 255/255.0, green: 69/255.0, blue: 58/255.0, alpha: 1)
            let lineWidth = max(0.5, side * 0.02)
            // Inset by HALF the stroke so the hairline's outer edge lands
            // exactly on the canvas edge — any less and it is clipped, any
            // more and width is wasted on transparency.
            let half = lineWidth / 2

            func plate(_ rect: NSRect, radius: CGFloat) {
                let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
                NSColor(calibratedWhite: 0.11, alpha: 0.88).setFill()
                path.fill()
                NSColor(calibratedWhite: 1, alpha: 0.16).setStroke()
                path.lineWidth = lineWidth
                path.stroke()
            }

            guard withText else {
                // Dot alone, on a square plate filling the tile.
                let body = NSRect(x: half, y: half,
                                  width: side - lineWidth, height: side - lineWidth)
                plate(body, radius: side * 0.225)
                let dot = side * 0.52
                red.setFill()
                NSBezierPath(ovalIn: NSRect(x: (side - dot) / 2, y: (side - dot) / 2,
                                            width: dot, height: dot)).fill()
                return true
            }

            // The plate spans the full canvas width; the badge is then grown
            // until it fills that width, rather than sized to a fixed
            // fraction and left floating in transparency.
            let plateWidth = side - lineWidth
            let gap = side * 0.08
            let minPad = side * 0.06

            // Largest type that still leaves at least minPad on each side.
            // The dot is tied to the cap height so the pair stays in
            // proportion as the type grows.
            var best: (font: NSFont, ink: CGRect, dot: CGFloat, line: CTLine)?
            var probe = side * 0.16
            while probe < side * 0.60 {
                let font = NSFont.systemFont(ofSize: probe, weight: .heavy)
                let attributed = NSAttributedString(string: "REC", attributes: [
                    .font: font,
                    .foregroundColor: NSColor.white,
                    .kern: -probe * 0.02,
                ])
                let line = CTLineCreateWithAttributedString(attributed)
                let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                let dot = ink.height * 1.15
                if dot + gap + ink.width <= plateWidth - minPad * 2 {
                    best = (font, ink, dot, line)
                } else {
                    break
                }
                probe += max(0.25, side * 0.01)
            }
            guard let fit = best else { return true }

            // Whatever width is left over becomes the padding — split evenly,
            // then reused vertically so all four sides match exactly.
            let contentWidth = fit.dot + gap + fit.ink.width
            let pad = (plateWidth - contentWidth) / 2
            let contentHeight = max(fit.dot, fit.ink.height)
            let plateHeight = contentHeight + pad * 2

            let plateRect = NSRect(x: half, y: (side - plateHeight) / 2,
                                   width: plateWidth, height: plateHeight)
            plate(plateRect, radius: min(plateHeight * 0.34, plateWidth / 2))

            red.setFill()
            NSBezierPath(ovalIn: NSRect(x: plateRect.minX + pad,
                                        y: plateRect.midY - fit.dot / 2,
                                        width: fit.dot, height: fit.dot)).fill()
            if let context = NSGraphicsContext.current?.cgContext {
                context.saveGState()
                context.textPosition = CGPoint(
                    x: plateRect.minX + pad + fit.dot + gap - fit.ink.minX,
                    y: plateRect.midY - fit.ink.height / 2 - fit.ink.minY)
                CTLineDraw(fit.line, context)
                context.restoreGState()
            }
            return true
        }
        return image
    }

    private static func rect(_ side: CGFloat) -> NSRect {
        NSRect(x: 0, y: 0, width: side, height: side)
    }

    static func write(_ image: NSImage, px: Int, to path: String) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .calibratedRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: path))
        print("  wrote \(px)x\(px)  \(path)")
    }

    static func main() {
        let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp"
        // 16pt slots: 16 px and 32 px. 32pt slots: 32 px and 64 px.
        // Text only earns its place from 32 px up.
        let slots: [(name: String, px: Int, text: Bool)] = [
            ("icon_16",     16, false),
            ("icon_16@2x",  32, true),
            ("icon_32",     32, true),
            ("icon_32@2x",  64, true),
        ]
        for s in slots {
            write(badge(px: s.px, withText: s.text), px: s.px,
                  to: "\(outDir)/\(s.name).png")
        }
        // Comparison sheet: both variants at each size, upscaled for review.
        let sheetScale = 6
        let sizes = [16, 32, 64]
        let sheet = NSImage(size: NSSize(width: 3 * 64 * sheetScale / 2,
                                         height: 2 * 64 * sheetScale / 2))
        sheet.lockFocus()
        NSColor(calibratedWhite: 0.55, alpha: 1).setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        for (row, withText) in [true, false].enumerated() {
            for (col, px) in sizes.enumerated() {
                let cell = CGFloat(64 * sheetScale / 2)
                let img = badge(px: px, withText: withText)
                let drawn = CGFloat(px * sheetScale / 2)
                img.draw(in: NSRect(x: CGFloat(col) * cell + (cell - drawn) / 2,
                                    y: sheet.size.height - CGFloat(row + 1) * cell + (cell - drawn) / 2,
                                    width: drawn, height: drawn))
            }
        }
        sheet.unlockFocus()
        let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
        try? rep.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: "\(outDir)/comparison.png"))
        print("  wrote comparison sheet (top row with REC, bottom row dot only)")
    }
}
