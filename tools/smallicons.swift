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
            let rect = NSRect(x: 0, y: 0, width: side, height: side)
            // Translucent dark rounded rect, inset slightly so the corners
            // read as a rounded square rather than filling the whole tile.
            let inset = max(0.5, side * 0.03)
            let body = rect.insetBy(dx: inset, dy: inset)
            let radius = side * 0.225
            let plate = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
            NSColor(calibratedWhite: 0.11, alpha: 0.88).setFill()
            plate.fill()
            // A hairline lifts it off dark desktops.
            NSColor(calibratedWhite: 1, alpha: 0.16).setStroke()
            plate.lineWidth = max(0.5, side * 0.02)
            plate.stroke()

            // #FF453A — sampled from the full icon, which is macOS systemRed.
            let red = NSColor(srgbRed: 255/255.0, green: 69/255.0, blue: 58/255.0, alpha: 1)
            if withText {
                // Dot + REC, laid out as one group and centred.
                let fontSize = side * 0.30
                let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
                let text = NSAttributedString(string: "REC", attributes: [
                    .font: font,
                    .foregroundColor: NSColor.white,
                    .kern: -fontSize * 0.02,
                ])
                let textSize = text.size()
                let dot = side * 0.20
                let gap = side * 0.07
                let total = dot + gap + textSize.width
                let originX = (side - total) / 2
                red.setFill()
                NSBezierPath(ovalIn: NSRect(x: originX,
                                            y: (side - dot) / 2,
                                            width: dot, height: dot)).fill()
                text.draw(at: NSPoint(x: originX + dot + gap,
                                      y: (side - textSize.height) / 2))
            } else {
                // Just the dot, big enough to read as the record symbol.
                let dot = side * 0.46
                red.setFill()
                NSBezierPath(ovalIn: NSRect(x: (side - dot) / 2, y: (side - dot) / 2,
                                            width: dot, height: dot)).fill()
            }
            return true
        }
        return image
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
