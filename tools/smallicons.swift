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
            // Equal padding on all four sides, so the plate hugs its contents.
            let pad = side * 0.085
            // …and a little air outside it, or the plate's hairline is clipped
            // by the tile edge.
            let outer = side * 0.04

            func plate(_ rect: NSRect, radius: CGFloat) {
                let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
                NSColor(calibratedWhite: 0.11, alpha: 0.88).setFill()
                path.fill()
                NSColor(calibratedWhite: 1, alpha: 0.16).setStroke()
                path.lineWidth = max(0.5, side * 0.02)
                path.stroke()
            }

            guard withText else {
                // Dot alone: a square plate already has equal padding.
                let body = rect(side).insetBy(dx: side * 0.03, dy: side * 0.03)
                plate(body, radius: side * 0.225)
                let dot = side * 0.46
                red.setFill()
                NSBezierPath(ovalIn: NSRect(x: (side - dot) / 2, y: (side - dot) / 2,
                                            width: dot, height: dot)).fill()
                return true
            }

            // Lay out by the glyphs' INK bounds, not the font's advance width
            // and line height: those include side bearings and the
            // ascender/descender the word "REC" never uses, so padding
            // computed from them comes out unequal — visibly so on the right.
            let usable = side - pad * 2 - outer * 2
            let dot = side * 0.22
            let gap = side * 0.08
            var fontSize = side * 0.34
            var line: CTLine!
            var ink = CGRect.zero
            while true {
                let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
                let attributed = NSAttributedString(string: "REC", attributes: [
                    .font: font,
                    .foregroundColor: NSColor.white,
                    .kern: -fontSize * 0.02,
                ])
                line = CTLineCreateWithAttributedString(attributed)
                ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                if dot + gap + ink.width <= usable || fontSize <= side * 0.16 { break }
                fontSize -= side * 0.01
            }

            let contentWidth = dot + gap + ink.width
            let contentHeight = max(dot, ink.height)
            let plateRect = NSRect(x: (side - (contentWidth + pad * 2)) / 2,
                                   y: (side - (contentHeight + pad * 2)) / 2,
                                   width: contentWidth + pad * 2,
                                   height: contentHeight + pad * 2)
            plate(plateRect, radius: min(plateRect.height * 0.34, plateRect.width / 2))

            red.setFill()
            NSBezierPath(ovalIn: NSRect(x: plateRect.minX + pad,
                                        y: plateRect.midY - dot / 2,
                                        width: dot, height: dot)).fill()

            // Place the ink rect exactly: shift by its own origin so the
            // leftmost pixel of "R" lands on the intended x, and the ink's
            // vertical centre lands on the plate's.
            if let context = NSGraphicsContext.current?.cgContext {
                context.saveGState()
                context.textPosition = CGPoint(
                    x: plateRect.minX + pad + dot + gap - ink.minX,
                    y: plateRect.midY - ink.height / 2 - ink.minY)
                CTLineDraw(line, context)
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
