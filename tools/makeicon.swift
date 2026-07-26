import AppKit

// Renders the sčrec app icon: a stylized monochrome macOS window (rounded
// rect, thick title bar) with "● REC" bottom-aligned; the dot is the only
// color. At >= 512 px the three window controls are stenciled out of the
// title bar as transparent holes.
let outDir = CommandLine.arguments[1]

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

    let winW = S * 0.86, winH = S * 0.68
    let winX = (S - winW) / 2, winY = (S - winH) / 2
    let corner = S * 0.075
    let win = CGRect(x: winX, y: winY, width: winW, height: winH)
    let body = NSBezierPath(roundedRect: win, xRadius: corner, yRadius: corner)

    // soft shadow for depth
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -S * 0.012),
                 blur: S * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor(white: 0.96, alpha: 1).setFill()
    body.fill()
    cg.restoreGState()

    // thick title bar (clipped to the window shape)
    let barH = winH * 0.26
    cg.saveGState()
    body.addClip()
    NSColor(white: 0.80, alpha: 1).setFill()
    NSBezierPath(rect: CGRect(x: winX, y: winY + winH - barH,
                              width: winW, height: barH)).fill()
    NSColor(white: 0.55, alpha: 1).setFill()
    NSBezierPath(rect: CGRect(x: winX, y: winY + winH - barH - S * 0.004,
                              width: winW, height: S * 0.006)).fill()
    cg.restoreGState()

    // outline
    NSColor(white: 0.33, alpha: 1).setStroke()
    body.lineWidth = max(1, S * 0.014)
    body.stroke()

    // traffic-light holes, highest resolutions only
    if px >= 512 {
        let r = barH * 0.15
        let cy = winY + winH - barH / 2
        var cx = winX + barH * 0.45
        cg.saveGState()
        cg.setBlendMode(.clear)
        for _ in 0..<3 {
            cg.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
            cx += r * 3.4
        }
        cg.restoreGState()
    }

    // "● REC" bottom-aligned in the window body
    let font = NSFont.systemFont(ofSize: winH * 0.30, weight: .heavy)
    let text = NSAttributedString(string: "REC", attributes: [
        .font: font,
        .foregroundColor: NSColor(white: 0.25, alpha: 1),
        .kern: winH * 0.012,
    ])
    let tSize = text.size()
    let dotD = tSize.height * 0.48
    let gap = dotD * 0.5
    let totalW = dotD + gap + tSize.width
    let baseX = winX + (winW - totalW) / 2
    let textY = winY + winH * 0.085
    NSColor.systemRed.setFill()
    NSBezierPath(ovalIn: CGRect(x: baseX, y: textY + tSize.height * 0.40 - dotD / 2,
                                width: dotD, height: dotD)).fill()
    text.draw(at: NSPoint(x: baseX + dotD + gap, y: textY))

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
