import AppKit

@main
enum ScrecMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // NSApplication.delegate is a weak reference; keep the delegate alive
        // for the entire run loop.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
