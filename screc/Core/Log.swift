import os

/// Central loggers. Errors that are deliberately swallowed as control flow
/// (`try?`, fire-and-forget completions) still get logged here, so "my
/// recording vanished" reports leave a trail in Console.app.
enum Log {
    static let app = Logger(subsystem: "app.screc", category: "app")
    static let engine = Logger(subsystem: "app.screc", category: "engine")
    static let store = Logger(subsystem: "app.screc", category: "store")
    static let gif = Logger(subsystem: "app.screc", category: "gif")
}
