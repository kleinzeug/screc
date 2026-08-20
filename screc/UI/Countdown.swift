import AppKit

/// The 3-2-1 overlay shown before capture starts (Settings toggle, off by
/// default). Deliberately NOT a key window and fully click-through: stealing
/// focus would change what "focused window" mode is about to record, and the
/// user may want to arrange windows during the count. Cancel goes through the
/// status item (any click) or the stop hotkey — both route to
/// `AppState.cancelCountdown()`.
@MainActor
final class CountdownController {
    private var window: CountdownWindow?
    private var timer: Timer?
    private var remaining = 0
    private var completion: ((Bool) -> Void)?

    /// `completion(true)` when the count ran out, `completion(false)` on
    /// cancel. Fires exactly once.
    func begin(on screen: NSScreen, seconds: Int = 3,
               completion: @escaping (Bool) -> Void) {
        finish(nil)
        self.completion = completion
        remaining = seconds
        let window = CountdownWindow(screen: screen)
        window.countdownView.value = seconds
        window.orderFrontRegardless()
        self.window = window
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func cancel() { finish(false) }

    private func tick() {
        remaining -= 1
        if remaining <= 0 {
            finish(true)
        } else {
            window?.countdownView.value = remaining
        }
    }

    private func finish(_ finished: Bool?) {
        timer?.invalidate()
        timer = nil
        window?.close()
        window = nil
        let handler = completion
        completion = nil
        if let finished { handler?(finished) }
    }
}

private final class CountdownWindow: NSWindow {
    let countdownView = CountdownView()

    init(screen: NSScreen) {
        let side: CGFloat = 220
        let frame = NSRect(x: screen.frame.midX - side / 2,
                           y: screen.frame.midY - side / 2,
                           width: side, height: side + 30)
        super.init(contentRect: frame, styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        contentView = countdownView
    }
}

private final class CountdownView: NSView {
    var value = 3 {
        didSet { if value != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        let side = min(bounds.width, bounds.height - 30)
        let plate = NSRect(x: bounds.midX - side / 2, y: bounds.maxY - side,
                           width: side, height: side)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(ovalIn: plate).fill()
        NSColor.white.withAlphaComponent(0.25).setStroke()
        let ring = NSBezierPath(ovalIn: plate.insetBy(dx: 3, dy: 3))
        ring.lineWidth = 4
        ring.stroke()

        let digit = "\(value)"
        let digitAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 110, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let digitSize = digit.size(withAttributes: digitAttributes)
        digit.draw(at: NSPoint(x: plate.midX - digitSize.width / 2,
                               y: plate.midY - digitSize.height / 2),
                   withAttributes: digitAttributes)

        let hint = "click the menu-bar ● to cancel"
        let hintAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        ]
        let hintSize = hint.size(withAttributes: hintAttributes)
        let hintOrigin = NSPoint(x: bounds.midX - hintSize.width / 2, y: 6)
        let hintPlate = NSRect(x: hintOrigin.x - 10, y: hintOrigin.y - 5,
                               width: hintSize.width + 20, height: hintSize.height + 10)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: hintPlate, xRadius: 7, yRadius: 7).fill()
        hint.draw(at: hintOrigin, withAttributes: hintAttributes)
    }
}
