import AppKit

/// Always-on-top, click-through "passe-partout": strongly dims every display
/// with a punched-out hole over what is being recorded. Purely visual — the
/// windows ignore all mouse events and never appear in a recording, because
/// the capture filter excludes screc's own application.
@MainActor
final class PassepartoutController {
    private var windows: [PassepartoutWindow] = []

    /// `hole` is in global AppKit (bottom-left origin) coordinates;
    /// nil dims everything (e.g. pinned window currently closed).
    func show(hole globalRect: NSRect?) {
        if windows.isEmpty {
            for screen in NSScreen.screens {
                let window = PassepartoutWindow(screen: screen)
                windows.append(window)
                window.orderFrontRegardless()
            }
        }
        update(hole: globalRect)
    }

    func update(hole globalRect: NSRect?) {
        for window in windows {
            guard let globalRect else {
                window.passepartoutView.hole = nil
                continue
            }
            let screenFrame = window.targetScreen.frame
            window.passepartoutView.hole = NSRect(
                x: globalRect.minX - screenFrame.minX,
                y: globalRect.minY - screenFrame.minY,
                width: globalRect.width,
                height: globalRect.height)
        }
    }

    func hide() {
        windows.forEach { $0.close() }
        windows = []
    }
}

private final class PassepartoutWindow: NSWindow {
    let targetScreen: NSScreen
    let passepartoutView = PassepartoutView()

    init(screen: NSScreen) {
        self.targetScreen = screen
        super.init(contentRect: screen.frame, styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true // indicator only — everything clicks through
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        contentView = passepartoutView
    }
}

private final class PassepartoutView: NSView {
    /// Window-local; may lie (partially) outside this screen, or be nil.
    var hole: NSRect? {
        didSet { if hole != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()
        guard let hole, hole.intersects(bounds) else { return }
        NSColor.clear.setFill()
        hole.fill(using: .copy)
    }
}
