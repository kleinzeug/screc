import AppKit

// Renders the sčrec app icon: a SQUARE stylized macOS window in the style of
// the AI artwork (charcoal title bar with inset window-control circles, soft
// light body, the dotREC wordmark bottom-aligned), plus a bright outline so
// the window reads on dark backgrounds. Everything is drawn at target size —
// nothing is scaled non-uniformly, so type, dot and corner radii stay true.
// Usage: swift makeicon.swift <dotREC.png> <outDir>
let logo = NSBitmapImageRep(data: try! Data(contentsOf:
    URL(fileURLWithPath: CommandLine.arguments[1])))!
let outDir = CommandLine.arguments[2]

let charcoal = NSColor(red: 0.20, green: 0.22, blue: 0.27, alpha: 1)
let charcoalDeep = NSColor(red: 0.13, green: 0.145, blue: 0.18, alpha: 1)

func render(px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    let S = CGFloat(px)

    let side = S * 0.84
    let winX = (S - side) / 2, winY = (S - side) / 2
    let corner = side * 0.13
    let win = CGRect(x: winX, y: winY, width: side, height: side)
    let windowPath = NSBezierPath(roundedRect: win, xRadius: corner, yRadius: corner)
    let barH = side * 0.22

    // base fill (title-bar charcoal) with a soft drop shadow
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -S * 0.012),
                 blur: S * 0.035, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    charcoal.setFill()
    windowPath.fill()
    cg.restoreGState()

    // body (window minus title bar), clipped to the window shape
    cg.saveGState()
    windowPath.addClip()
    let bodyRect = CGRect(x: winX, y: winY, width: side, height: side - barH)
    NSColor(red: 0.985, green: 0.99, blue: 1.0, alpha: 1).setFill()
    NSBezierPath(rect: bodyRect).fill()
    NSGradient(colors: [NSColor(red: 0.86, green: 0.92, blue: 0.96, alpha: 0.9),
                        NSColor(calibratedWhite: 1, alpha: 0)])?
        .draw(in: NSBezierPath(rect: bodyRect), angle: 90)

    // two soft wave bands like the artwork
    if px >= 64 {
        for (level, alpha) in [(0.62, 0.35), (0.74, 0.25)] {
            let y = winY + bodyRect.height * CGFloat(level)
            let wave = NSBezierPath()
            wave.move(to: NSPoint(x: winX, y: y))
            wave.curve(to: NSPoint(x: winX + side, y: y + side * 0.10),
                       controlPoint1: NSPoint(x: winX + side * 0.35, y: y - side * 0.06),
                       controlPoint2: NSPoint(x: winX + side * 0.65, y: y + side * 0.14))
            wave.line(to: NSPoint(x: winX + side, y: bodyRect.maxY))
            wave.line(to: NSPoint(x: winX, y: bodyRect.maxY))
            wave.close()
            NSColor(red: 0.78, green: 0.87, blue: 0.94, alpha: alpha).setFill()
            wave.fill()
        }
    }

    // inset window-control circles in the title bar
    if px >= 64 {
        let r = barH * 0.14
        let cy = winY + side - barH / 2
        var cx = winX + barH * 0.42
        for _ in 0..<3 {
            charcoalDeep.setFill()
            NSBezierPath(ovalIn: CGRect(x: cx - r, y: cy - r,
                                        width: 2 * r, height: 2 * r)).fill()
            cx += r * 3.3
        }
    }

    // dotREC wordmark, bottom-aligned in the body
    let logoH = side * 0.185
    let logoW = logoH * CGFloat(logo.pixelsWide) / CGFloat(logo.pixelsHigh)
    logo.draw(in: CGRect(x: winX + (side - logoW) / 2,
                         y: winY + side * 0.115,
                         width: logoW, height: logoH),
              from: .zero, operation: .sourceOver, fraction: 1,
              respectFlipped: false,
              hints: [.interpolation: NSImageInterpolation.high.rawValue])
    cg.restoreGState()

    // bright outline so the charcoal window reads on dark backgrounds
    NSColor(calibratedWhite: 0.96, alpha: 0.9).setStroke()
    windowPath.lineWidth = max(1, S * 0.011)
    windowPath.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let files: [(Int, String)] = [
    (16, "icon_16.png"), (32, "icon_16@2x.png"), (32, "icon_32.png"),
    (64, "icon_32@2x.png"), (128, "icon_128.png"), (256, "icon_128@2x.png"),
    (256, "icon_256.png"), (512, "icon_256@2x.png"), (512, "icon_512.png"),
    (1024, "icon_512@2x.png"),
]
var cache: [Int: Data] = [:]
for (px, name) in files {
    if cache[px] == nil {
        cache[px] = render(px: px).representation(using: .png, properties: [:])!
    }
    try! cache[px]!.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
}
print("wrote \(files.count) icons")
