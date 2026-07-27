import Cocoa
import WebKit

// Renders a local HTML file to a PNG at an exact pixel size, for social
// preview / OG images. No headless browser needed — WKWebView draws it.
// Usage: swift rendershot.swift <input.html> <output.png> <width> <height> [settleSeconds]

let args = CommandLine.arguments
guard args.count >= 5 else {
    FileHandle.standardError.write("usage: rendershot <in.html> <out.png> <w> <h> [settle]\n".data(using: .utf8)!)
    exit(2)
}
let inputURL = URL(fileURLWithPath: args[1])
let outputURL = URL(fileURLWithPath: args[2])
let width = Int(args[3])!
let height = Int(args[4])!
let settle = args.count > 5 ? Double(args[5])! : 1.2

final class Shooter: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let window: NSWindow

    override init() {
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        let config = WKWebViewConfiguration()
        web = WKWebView(frame: frame, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        // Offscreen window: WebKit needs a hosting window to compose layers.
        window = NSWindow(contentRect: frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.contentView = web
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderBack(nil)
        super.init()
        web.navigationDelegate = self
    }

    func load() {
        web.loadFileURL(inputURL, allowingReadAccessTo: inputURL.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Let webfonts, canvas and any entry animation settle first.
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [self] in
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(x: 0, y: 0, width: width, height: height)
            config.snapshotWidth = NSNumber(value: width)
            web.takeSnapshot(with: config) { image, error in
                guard let image, let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:])
                else {
                    FileHandle.standardError.write(
                        "snapshot failed: \(error?.localizedDescription ?? "unknown")\n"
                            .data(using: .utf8)!)
                    exit(1)
                }
                do {
                    try png.write(to: outputURL)
                    print("wrote \(outputURL.lastPathComponent) — \(rep.pixelsWide)×\(rep.pixelsHigh)")
                    exit(0)
                } catch {
                    FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!)
                    exit(1)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write("load failed: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let shooter = Shooter()
shooter.load()
app.run()
