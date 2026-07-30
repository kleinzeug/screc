import AppKit
import CoreGraphics

/// Global observation of mouse buttons, scrolling and key presses, feeding the
/// input-visualization overlay while recording.
///
/// Two different permission worlds:
///  - Mouse buttons and scroll wheel come through a global NSEvent monitor and
///    need no privacy grant.
///  - Key events need **Input Monitoring** (`kTCCServiceListenEvent`). The key
///    monitor is only installed when a keyboard visualization is switched on,
///    so screc never asks for it otherwise.
///
/// Cursor position is polled by the overlay (60 Hz `NSEvent.mouseLocation`)
/// rather than monitored, which keeps the high-frequency path out of here.
@MainActor
final class InputMonitor {
    /// Mouse button numbers as AppKit reports them.
    enum Button: Int { case left = 0, right = 1, middle = 2 }

    var onButton: ((Button, Bool) -> Void)?
    /// Accumulated wheel movement, in "lines" (sign preserved).
    var onScroll: ((Double) -> Void)?
    /// A key press: the key's own label, plus the modifier symbols held with
    /// it (empty when it was an unmodified keystroke).
    var onKey: ((String, [String]) -> Void)?

    private var mouseMonitor: Any?
    private var keyMonitor: Any?

    // MARK: Permission (keys only)

    static var keyAccessGranted: Bool { CGPreflightListenEventAccess() }

    /// Shows the system prompt the first time; afterwards only System Settings
    /// can change it (same one-shot behavior as screen recording).
    static func requestKeyAccess() { _ = CGRequestListenEventAccess() }

    static func openInputMonitoringSettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    // MARK: Lifecycle

    func start(wantsMouse: Bool, wantsKeys: Bool) {
        stop()
        if wantsMouse {
            let mask: NSEvent.EventTypeMask = [
                .leftMouseDown, .leftMouseUp,
                .rightMouseDown, .rightMouseUp,
                .otherMouseDown, .otherMouseUp,
                .scrollWheel,
            ]
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                MainActor.assumeIsolated { self?.handleMouse(event) }
            }
        }
        // Installing this is what would trigger the Input Monitoring prompt —
        // only do it when a keyboard visualization actually wants it.
        if wantsKeys, Self.keyAccessGranted {
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.handleKey(event) }
            }
        } else if wantsKeys {
            Log.app.notice("key visualization enabled without Input Monitoring — keys will not appear")
        }
    }

    func stop() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        mouseMonitor = nil
        keyMonitor = nil
    }

    // MARK: Events

    private func handleMouse(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown: onButton?(.left, true)
        case .leftMouseUp: onButton?(.left, false)
        case .rightMouseDown: onButton?(.right, true)
        case .rightMouseUp: onButton?(.right, false)
        case .otherMouseDown:
            if event.buttonNumber == 2 { onButton?(.middle, true) }
        case .otherMouseUp:
            if event.buttonNumber == 2 { onButton?(.middle, false) }
        case .scrollWheel:
            // Prefer the precise trackpad/high-res delta when present.
            let delta = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY / 10
                : event.scrollingDeltaY
            if delta != 0 { onScroll?(Double(delta)) }
        default:
            break
        }
    }

    private func handleKey(_ event: NSEvent) {
        guard let label = Self.label(for: event) else { return }
        onKey?(label, Self.modifierSymbols(event.modifierFlags))
    }

    // MARK: Labels

    /// Canonical Apple order, the way shortcuts are written: ⌃⌥⇧⌘.
    static func modifierSymbols(_ flags: NSEvent.ModifierFlags) -> [String] {
        var symbols: [String] = []
        if flags.contains(.control) { symbols.append("⌃") }
        if flags.contains(.option) { symbols.append("⌥") }
        if flags.contains(.shift) { symbols.append("⇧") }
        if flags.contains(.command) { symbols.append("⌘") }
        return symbols
    }

    /// Keys whose character is unprintable or misleading get an explicit name.
    private static let specialLabels: [UInt16: String] = [
        36: "return", 48: "tab", 49: "space", 51: "delete", 53: "esc",
        76: "enter", 117: "fwd del", 115: "home", 119: "end",
        116: "page up", 121: "page dn",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    static func label(for event: NSEvent) -> String? {
        if let special = specialLabels[event.keyCode] { return special }
        // charactersIgnoringModifiers keeps ⌥-combinations readable (⌥C is C,
        // not ç) — but shift is folded in, hence the uppercasing below.
        guard let characters = event.charactersIgnoringModifiers,
              let first = characters.first,
              !first.isNewline
        else { return nil }
        return String(first).uppercased()
    }
}
