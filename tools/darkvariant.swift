import AppKit

// dotREC dark-mode variant: recolor non-red opaque pixels to white,
// preserving alpha (the red dot stays red).
let src = NSBitmapImageRep(data: try! Data(contentsOf:
    URL(fileURLWithPath: CommandLine.arguments[1])))!
let w = src.pixelsWide, h = src.pixelsHigh
let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
for y in 0..<h {
    for x in 0..<w {
        guard let c = src.colorAt(x: x, y: y) else { continue }
        let redness = c.redComponent - max(c.greenComponent, c.blueComponent)
        let color = redness > 0.15
            ? c
            : NSColor(red: 1, green: 1, blue: 1, alpha: c.alphaComponent)
        out.setColor(color.withAlphaComponent(c.alphaComponent), atX: x, y: y)
    }
}
try! out.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("dark variant written")
