import AppKit

@MainActor
enum RecordingOpener {
    /// MP4 → QuickTime Player (trim + lossless Save); GIF → Preview.
    static func open(_ url: URL) {
        let bundleID = url.pathExtension.lowercased() == "gif"
            ? "com.apple.Preview"
            : "com.apple.QuickTimePlayerX"
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
