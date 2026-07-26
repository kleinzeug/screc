import AppKit

// Slices tools/icon-master.png (1024 full-bleed square) into the AppIcon set:
// masked to the macOS icon-grid rounded square (82% of canvas, ~22% corner
// radius), slightly zoomed so the window artwork fills the tile.
let master = NSBitmapImageRep(data: try! Data(contentsOf:
    URL(fileURLWithPath: CommandLine.arguments[1])))!
let outDir = CommandLine.arguments[2]

func render(px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
    let S = CGFloat(px)
    let tile = S * 0.82
    let tileRect = CGRect(x: (S - tile) / 2, y: (S - tile) / 2, width: tile, height: tile)
    NSBezierPath(roundedRect: tileRect, xRadius: tile * 0.225, yRadius: tile * 0.225).addClip()
    let zoom = tile * 1.18
    let drawRect = CGRect(x: (S - zoom) / 2, y: (S - zoom) / 2, width: zoom, height: zoom)
    master.draw(in: drawRect, from: .zero, operation: .sourceOver,
                fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high.rawValue])
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
print("sliced \(files.count) icons")
