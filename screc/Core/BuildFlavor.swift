import Foundation

/// How this copy of screc was obtained. App Store builds carry a receipt;
/// anything else was built from source (or downloaded directly), which is
/// where pointing at the repository and the tip jar makes sense.
enum BuildFlavor {
    static let appStoreURL = URL(string: "https://apps.apple.com/app/screc")!
    static let siteURL = URL(string: "https://screc.app")!
    static let repositoryURL = URL(string: "https://github.com/kleinzeug/screc")!
    static let coffeeURL = URL(string: "https://www.buymeacoffee.com/holzschneider")!

    static var isAppStoreBuild: Bool {
        // Mac App Store copies carry Contents/_MASReceipt/receipt. Checking
        // the path directly avoids the deprecated appStoreReceiptURL.
        let receipt = Bundle.main.bundleURL
            .appendingPathComponent("Contents/_MASReceipt/receipt")
        return FileManager.default.fileExists(atPath: receipt.path)
    }

    /// Self-compiled or direct download: show the source and support links.
    static var showsSourceLinks: Bool { !isAppStoreBuild }
}
