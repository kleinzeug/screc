import AppKit
import QuartzCore

/// Input visualization drawn ON TOP of the screen while recording — cursor
/// magnification, click rings, a scroll wheel, a stylized keyboard and key
/// combination chips.
///
/// Unlike every other screc window, these overlays MUST appear in the
/// recording, so they deliberately keep the default `sharingType`
/// (`.readWrite`) and the capture filter is told to include them by window id
/// (see `ScreenRecorderEngine.includedWindowIDs`). They are click-through, so
/// the user keeps working underneath them.
///
/// Only display and region recordings can show them: a window-scoped filter
/// composites just that window, so nothing drawn beside it can be captured.
@MainActor
final class InputOverlayController {
    private var windows: [InputOverlayWindow] = []
    private let monitor = InputMonitor()
    private var timer: Timer?
    private var state = InputVisualState()

    /// Starts monitoring and shows the overlays. Returns the window ids the
    /// capture filter has to include, so the decorations land in the file.
    @discardableResult
    func start(hudScreen: NSScreen?) -> [CGWindowID] {
        stop()
        state = InputVisualState()
        state.doubleCursor = Prefs.showsCursor && Prefs.doubleCursorSize
        state.showsClicks = Prefs.showsMouseClicks
        state.showsScroll = Prefs.showsMouseScroll
        state.showsKeyboard = Prefs.showsKeyStrokes
        state.showsCombos = Prefs.showsKeyCombinations
        state.mouse = NSEvent.mouseLocation

        let hud = hudScreen ?? NSScreen.main ?? NSScreen.screens.first
        for screen in NSScreen.screens {
            let window = InputOverlayWindow(screen: screen,
                                            isHUDScreen: screen == hud)
            window.overlayView.state = state
            window.orderFrontRegardless()
            windows.append(window)
        }

        monitor.onButton = { [weak self] button, isDown in
            guard let self else { return }
            if isDown { state.buttons.insert(button.rawValue) }
            else { state.buttons.remove(button.rawValue) }
            push()
        }
        monitor.onScroll = { [weak self] delta in
            guard let self else { return }
            // 12° per line keeps the wheel's rotation legible rather than a blur.
            state.scrollAngle -= delta * 12
            state.lastScroll = CACurrentMediaTime()
            push()
        }
        monitor.onKey = { [weak self] label, modifiers in
            guard let self else { return }
            let now = CACurrentMediaTime()
            if state.showsKeyboard {
                state.keys.append(InputVisualState.KeyHit(label: label, time: now))
                if state.keys.count > 12 { state.keys.removeFirst() }
                state.lastKey = now
            }
            // A bare keystroke is not a "combination" — only ⌃/⌥/⌘ make it one
            // (⇧A is just typing).
            if state.showsCombos,
               modifiers.contains(where: { $0 != "⇧" }) {
                state.combo = InputVisualState.ComboHit(chips: modifiers + [label],
                                                        time: now)
            }
            push()
        }
        monitor.start(wantsMouse: state.showsClicks || state.showsScroll || state.doubleCursor,
                      wantsKeys: state.showsKeyboard || state.showsCombos)

        // One clock drives cursor tracking and every fade-out.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.current.add(timer, forMode: .common)
        self.timer = timer

        return windows.compactMap { CGWindowID(exactly: $0.windowNumber) }
    }

    func stop() {
        monitor.stop()
        monitor.onButton = nil
        monitor.onScroll = nil
        monitor.onKey = nil
        timer?.invalidate()
        timer = nil
        windows.forEach { $0.close() }
        windows = []
    }

    private func tick() {
        let now = CACurrentMediaTime()
        var changed = false

        if state.doubleCursor || state.showsClicks || state.showsScroll {
            let mouse = NSEvent.mouseLocation
            if mouse != state.mouse {
                state.mouse = mouse
                changed = true
            }
            if state.doubleCursor {
                // The system cursor changes shape over text fields, links, …
                let image = NSCursor.currentSystem?.image
                if image !== state.cursorImage {
                    state.cursorImage = image
                    state.cursorHotSpot = NSCursor.currentSystem?.hotSpot ?? .zero
                    changed = true
                }
            }
        }
        // Prune whatever has faded out; each removal needs one more redraw.
        if !state.keys.isEmpty {
            let kept = state.keys.filter { now - $0.time < InputVisualState.keyboardLinger }
            if kept.count != state.keys.count { state.keys = kept; changed = true }
        }
        if state.keys.isEmpty, state.lastKey != nil { state.lastKey = nil; changed = true }
        if let combo = state.combo, now - combo.time > InputVisualState.comboLinger {
            state.combo = nil
            changed = true
        }
        if let scroll = state.lastScroll, now - scroll > InputVisualState.scrollLinger {
            state.lastScroll = nil
            changed = true
        }
        // Highlights and fades are time-based, so keep redrawing while any
        // decoration is on screen.
        if state.hasTransientContent { changed = true }
        if changed { push() }
    }

    private func push() {
        for window in windows {
            window.overlayView.state = state
        }
    }
}

// MARK: - Visual state

/// Everything the overlay draws, in global (AppKit) coordinates.
struct InputVisualState {
    struct KeyHit {
        let label: String
        let time: CFTimeInterval
    }
    struct ComboHit {
        let chips: [String]
        let time: CFTimeInterval
    }

    static let keyHighlight: CFTimeInterval = 0.35
    static let keyboardLinger: CFTimeInterval = 2.0
    static let comboLinger: CFTimeInterval = 1.4
    static let scrollLinger: CFTimeInterval = 0.7

    var doubleCursor = false
    var showsClicks = false
    var showsScroll = false
    var showsKeyboard = false
    var showsCombos = false

    var mouse: NSPoint = .zero
    var cursorImage: NSImage?
    var cursorHotSpot: NSPoint = .zero
    /// Button numbers currently held (0 left, 1 right, 2 middle).
    var buttons: Set<Int> = []
    var scrollAngle: Double = 0
    var lastScroll: CFTimeInterval?
    var keys: [KeyHit] = []
    var lastKey: CFTimeInterval?
    var combo: ComboHit?

    /// True while something time-dependent is visible, so the view keeps
    /// redrawing instead of freezing mid-fade.
    var hasTransientContent: Bool {
        lastScroll != nil || combo != nil || !keys.isEmpty || !buttons.isEmpty
    }
}

// MARK: - Window

private final class InputOverlayWindow: NSWindow {
    let overlayView: InputOverlayView

    init(screen: NSScreen, isHUDScreen: Bool) {
        overlayView = InputOverlayView(screenFrame: screen.frame,
                                       isHUDScreen: isHUDScreen)
        super.init(contentRect: screen.frame, styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        // Above the passe-partout, below nothing that matters.
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // DELIBERATELY capturable — the whole point is to appear in the
        // recording. Every other screc window sets .none here.
        sharingType = .readWrite
        isReleasedWhenClosed = false
        contentView = overlayView
    }
}

// MARK: - Drawing

private final class InputOverlayView: NSView {
    private let screenFrame: NSRect
    private let isHUDScreen: Bool
    /// Bounds of the last frame's decorations, so redraws stay local.
    private var lastDirty: NSRect = .zero

    var state = InputVisualState() {
        didSet { invalidateDecorations() }
    }

    init(screenFrame: NSRect, isHUDScreen: Bool) {
        self.screenFrame = screenFrame
        self.isHUDScreen = isHUDScreen
        super.init(frame: NSRect(origin: .zero, size: screenFrame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func local(_ global: NSPoint) -> NSPoint {
        NSPoint(x: global.x - screenFrame.minX, y: global.y - screenFrame.minY)
    }

    /// Union of what was and what will be drawn — everything else is left be.
    private func invalidateDecorations() {
        let current = decorationBounds()
        let dirty = lastDirty.isEmpty ? current : lastDirty.union(current)
        lastDirty = current
        guard !dirty.isEmpty else { return }
        setNeedsDisplay(dirty.insetBy(dx: -4, dy: -4))
    }

    private func decorationBounds() -> NSRect {
        var rect = NSRect.zero
        let mouseIsHere = screenFrame.contains(state.mouse)
        if mouseIsHere {
            let point = local(state.mouse)
            // Generous: covers ring, wheel and a 2× cursor of any shape.
            rect = rect.union(NSRect(x: point.x - 120, y: point.y - 120,
                                     width: 240, height: 240))
        }
        if isHUDScreen {
            if !state.keys.isEmpty {
                rect = rect.union(Self.keyboardFrame(in: bounds).insetBy(dx: -8, dy: -8))
            }
            if state.combo != nil {
                rect = rect.union(comboBand())
            }
        }
        return rect
    }

    /// Full-width band the combo chips can occupy (their width varies with the
    /// chip count, so reserve the row).
    private func comboBand() -> NSRect {
        let keyboard = Self.keyboardFrame(in: bounds)
        let y = state.keys.isEmpty
            ? bounds.midY - 26
            : keyboard.maxY + 14
        return NSRect(x: bounds.minX, y: y - 8, width: bounds.width, height: 64)
    }

    override func draw(_ dirtyRect: NSRect) {
        let now = CACurrentMediaTime()

        if screenFrame.contains(state.mouse) {
            let point = local(state.mouse)
            if state.showsScroll, let last = state.lastScroll {
                let age = now - last
                let alpha = 1 - min(1, age / InputVisualState.scrollLinger)
                drawScrollWheel(at: NSPoint(x: point.x + 46, y: point.y),
                                angle: state.scrollAngle, alpha: alpha)
            }
            if state.showsClicks, !state.buttons.isEmpty {
                drawClickRing(at: point, buttons: state.buttons)
            }
            if state.doubleCursor, let image = state.cursorImage {
                drawDoubledCursor(image, hotSpot: state.cursorHotSpot, at: point)
            }
        }

        guard isHUDScreen else { return }
        if state.showsKeyboard, !state.keys.isEmpty, let lastKey = state.lastKey {
            let age = now - lastKey
            let fade = age > InputVisualState.keyboardLinger - 0.4
                ? max(0, (InputVisualState.keyboardLinger - age) / 0.4)
                : 1
            drawKeyboard(alpha: fade, now: now)
        }
        if state.showsCombos, let combo = state.combo {
            let age = now - combo.time
            let fade = age > InputVisualState.comboLinger - 0.35
                ? max(0, (InputVisualState.comboLinger - age) / 0.35)
                : 1
            drawCombo(combo, alpha: fade)
        }
    }

    // MARK: Mouse decorations

    /// Ring around the pointer: the left half lights up for a left click, the
    /// right half for a right click, and a wheel glyph in the middle for the
    /// middle button.
    private func drawClickRing(at point: NSPoint, buttons: Set<Int>) {
        let radius: CGFloat = 26
        let highlight = NSColor.systemBlue.withAlphaComponent(0.45)

        if buttons.contains(0) { fillHalf(at: point, radius: radius, left: true, color: highlight) }
        if buttons.contains(1) { fillHalf(at: point, radius: radius, left: false, color: highlight) }

        let ring = NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius,
                                               width: radius * 2, height: radius * 2))
        ring.lineWidth = 3.5
        NSColor.black.withAlphaComponent(0.35).setStroke()
        ring.stroke()
        ring.lineWidth = 2
        NSColor.white.withAlphaComponent(0.95).setStroke()
        ring.stroke()

        if buttons.contains(2) {
            drawWheelGlyph(at: point, angle: 0, alpha: 1, highlighted: true)
        }
    }

    private func fillHalf(at center: NSPoint, radius: CGFloat, left: Bool, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: center)
        // Counterclockwise: 90→270 sweeps through 180° (left), 270→90 through 0° (right).
        path.appendArc(withCenter: center, radius: radius,
                       startAngle: left ? 90 : 270,
                       endAngle: left ? 270 : 90)
        path.close()
        color.setFill()
        path.fill()
    }

    /// Side view of a mouse wheel; `angle` rotates its ticks.
    private func drawWheelGlyph(at center: NSPoint, angle: Double, alpha: Double,
                                highlighted: Bool) {
        let size = NSSize(width: 13, height: 20)
        let body = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                          width: size.width, height: size.height)
        let path = NSBezierPath(roundedRect: body,
                                xRadius: size.width / 2, yRadius: size.width / 2)
        (highlighted ? NSColor.systemBlue : NSColor.black)
            .withAlphaComponent(highlighted ? 0.85 * alpha : 0.55 * alpha).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.95 * alpha).setStroke()
        path.lineWidth = 1.5
        path.stroke()

        // Ticks scroll along the wheel to show movement and direction.
        NSColor.white.withAlphaComponent(0.9 * alpha).setStroke()
        let spacing: CGFloat = 6
        let phase = CGFloat(angle.truncatingRemainder(dividingBy: Double(spacing)))
        var y = body.minY + 3 + phase
        while y < body.maxY - 3 {
            if y > body.minY + 2, y < body.maxY - 2 {
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: body.minX + 3.5, y: y))
                tick.line(to: NSPoint(x: body.maxX - 3.5, y: y))
                tick.lineWidth = 1.2
                tick.stroke()
            }
            y += spacing
        }
    }

    private func drawScrollWheel(at point: NSPoint, angle: Double, alpha: Double) {
        drawWheelGlyph(at: point, angle: angle, alpha: alpha, highlighted: false)
    }

    /// A 2× copy of the live cursor, anchored so its hot spot stays on the real
    /// pointer position. Cursor images are top-left-origin, hence the flip.
    private func drawDoubledCursor(_ image: NSImage, hotSpot: NSPoint, at point: NSPoint) {
        let scaled = NSSize(width: image.size.width * 2, height: image.size.height * 2)
        let origin = NSPoint(x: point.x - hotSpot.x * 2,
                             y: point.y + hotSpot.y * 2 - scaled.height)
        image.draw(in: NSRect(origin: origin, size: scaled),
                   from: .zero, operation: .sourceOver, fraction: 1)
    }

    // MARK: Keyboard HUD

    private static let keyUnit: CGFloat = 22
    private static let keyGap: CGFloat = 3

    /// Stylized ANSI-ish layout: (label, width in key units).
    private static let rows: [[(String, CGFloat)]] = [
        [("`", 1), ("1", 1), ("2", 1), ("3", 1), ("4", 1), ("5", 1), ("6", 1),
         ("7", 1), ("8", 1), ("9", 1), ("0", 1), ("-", 1), ("=", 1), ("delete", 1.7)],
        [("tab", 1.5), ("Q", 1), ("W", 1), ("E", 1), ("R", 1), ("T", 1), ("Y", 1),
         ("U", 1), ("I", 1), ("O", 1), ("P", 1), ("[", 1), ("]", 1), ("\\", 1.2)],
        [("caps", 1.8), ("A", 1), ("S", 1), ("D", 1), ("F", 1), ("G", 1), ("H", 1),
         ("J", 1), ("K", 1), ("L", 1), (";", 1), ("'", 1), ("return", 1.9)],
        [("⇧", 2.4), ("Z", 1), ("X", 1), ("C", 1), ("V", 1), ("B", 1), ("N", 1),
         ("M", 1), (",", 1), (".", 1), ("/", 1), ("⇧", 2.3)],
        [("⌃", 1.2), ("⌥", 1.2), ("⌘", 1.4), ("space", 6), ("⌘", 1.4), ("⌥", 1.2),
         ("←", 1), ("↑", 1), ("↓", 1), ("→", 1)],
    ]

    private static func rowWidth(_ row: [(String, CGFloat)]) -> CGFloat {
        row.reduce(0) { $0 + $1.1 * keyUnit } + CGFloat(row.count - 1) * keyGap
    }

    /// Centred both ways, as specified.
    static func keyboardFrame(in bounds: NSRect) -> NSRect {
        let width = rows.map(rowWidth).max() ?? 0
        let height = CGFloat(rows.count) * keyUnit + CGFloat(rows.count - 1) * keyGap
        let padding: CGFloat = 12
        return NSRect(x: bounds.midX - (width + padding * 2) / 2,
                      y: bounds.midY - (height + padding * 2) / 2,
                      width: width + padding * 2,
                      height: height + padding * 2)
    }

    private func drawKeyboard(alpha: Double, now: CFTimeInterval) {
        let frame = Self.keyboardFrame(in: bounds)
        let body = NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12)
        NSColor.black.withAlphaComponent(0.55 * alpha).setFill()
        body.fill()
        NSColor.white.withAlphaComponent(0.18 * alpha).setStroke()
        body.lineWidth = 1
        body.stroke()

        // Labels pressed recently enough to still be lit.
        let lit = Set(state.keys
            .filter { now - $0.time < InputVisualState.keyHighlight }
            .map { $0.label.lowercased() })

        var y = frame.maxY - 12 - Self.keyUnit
        for row in Self.rows {
            var x = frame.midX - Self.rowWidth(row) / 2
            for (label, widthUnits) in row {
                let width = widthUnits * Self.keyUnit
                let keyRect = NSRect(x: x, y: y, width: width, height: Self.keyUnit)
                let isLit = lit.contains(label.lowercased())
                let key = NSBezierPath(roundedRect: keyRect.insetBy(dx: 0.5, dy: 0.5),
                                       xRadius: 4, yRadius: 4)
                (isLit ? NSColor.systemBlue.withAlphaComponent(0.9 * alpha)
                       : NSColor.white.withAlphaComponent(0.10 * alpha)).setFill()
                key.fill()
                NSColor.white.withAlphaComponent((isLit ? 0.95 : 0.22) * alpha).setStroke()
                key.lineWidth = 1
                key.stroke()

                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: label.count > 2 ? 8 : 11,
                                             weight: isLit ? .bold : .medium),
                    .foregroundColor: NSColor.white
                        .withAlphaComponent((isLit ? 1 : 0.75) * alpha),
                ]
                let size = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: keyRect.midX - size.width / 2,
                                       y: keyRect.midY - size.height / 2),
                           withAttributes: attributes)
                x += width + Self.keyGap
            }
            y -= Self.keyUnit + Self.keyGap
        }
    }

    // MARK: Combination chips

    /// Chips sit above the keyboard when it is on screen, so the two never
    /// overlap; centred on their own otherwise.
    private func drawCombo(_ combo: InputVisualState.ComboHit, alpha: Double) {
        let font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        ]
        let gap: CGFloat = 8
        let sizes = combo.chips.map { $0.size(withAttributes: attributes) }
        let widths = sizes.map { max(44, $0.width + 26) }
        let height: CGFloat = 44
        let total = widths.reduce(0, +) + CGFloat(combo.chips.count - 1) * gap

        let keyboardVisible = state.showsKeyboard && !state.keys.isEmpty
        let y = keyboardVisible
            ? Self.keyboardFrame(in: bounds).maxY + 14
            : bounds.midY - height / 2
        var x = bounds.midX - total / 2

        for (index, chip) in combo.chips.enumerated() {
            let rect = NSRect(x: x, y: y, width: widths[index], height: height)
            let body = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
            NSColor.black.withAlphaComponent(0.7 * alpha).setFill()
            body.fill()
            NSColor.white.withAlphaComponent(0.5 * alpha).setStroke()
            body.lineWidth = 1.5
            body.stroke()
            let size = sizes[index]
            chip.draw(at: NSPoint(x: rect.midX - size.width / 2,
                                  y: rect.midY - size.height / 2),
                      withAttributes: attributes)
            x += widths[index] + gap
        }
    }
}
