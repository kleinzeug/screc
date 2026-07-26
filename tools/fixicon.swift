import AppKit

// Repairs an icon PNG whose background removal also knocked out interior
// whites: transparency connected to the canvas border stays transparent
// (true exterior); every other transparent/translucent pixel is composited
// over white. Output is padded to a square canvas.
// Usage: fixicon <in.png> <out.png>
let src = NSBitmapImageRep(data: try! Data(contentsOf:
    URL(fileURLWithPath: CommandLine.arguments[1])))!
let w = src.pixelsWide, h = src.pixelsHigh

// Redraw into a known premultiplied RGBA8 layout.
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 4 * w, bitsPerPixel: 32)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
src.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
NSGraphicsContext.restoreGraphicsState()

let data = rep.bitmapData!
let rowBytes = rep.bytesPerRow

@inline(__always) func alpha(_ x: Int, _ y: Int) -> UInt8 {
    data[y * rowBytes + x * 4 + 3]
}

// BFS from all border pixels across near-transparent pixels → exterior mask.
var exterior = [Bool](repeating: false, count: w * h)
var stack: [Int] = []
func seed(_ x: Int, _ y: Int) {
    if alpha(x, y) < 10 && !exterior[y * w + x] {
        exterior[y * w + x] = true
        stack.append(y * w + x)
    }
}
for x in 0..<w { seed(x, 0); seed(x, h - 1) }
for y in 0..<h { seed(0, y); seed(w - 1, y) }
while let index = stack.popLast() {
    let x = index % w, y = index / w
    for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
        guard nx >= 0, nx < w, ny >= 0, ny < h, !exterior[ny * w + nx],
              alpha(nx, ny) < 10 else { continue }
        exterior[ny * w + nx] = true
        stack.append(ny * w + nx)
    }
}

// Composite interior holes over white (premultiplied: c' = c + (255 - a)).
var repaired = 0
for y in 0..<h {
    for x in 0..<w {
        guard !exterior[y * w + x] else { continue }
        let p = y * rowBytes + x * 4
        let a = data[p + 3]
        if a < 255 {
            let fill = 255 - Int(a)
            for c in 0..<3 {
                data[p + c] = UInt8(min(255, Int(data[p + c]) + fill))
            }
            data[p + 3] = 255
            repaired += 1
        }
    }
}

// Pad to a square canvas, centered.
let side = max(w, h)
let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
rep.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
NSGraphicsContext.restoreGraphicsState()
try! out.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("repaired \(repaired) interior pixels, canvas \(side)x\(side)")
