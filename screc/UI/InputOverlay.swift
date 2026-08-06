import AppKit
import CoreVideo
import QuartzCore
import os

/// Input visualization — cursor magnification, click rings, a scroll wheel, a
/// stylized keyboard and key-combination chips.
///
/// These are drawn INTO the recorded frames, not onto the screen. An overlay
/// window would be the obvious implementation, but ScreenCaptureKit composites
/// what is actually on screen: a window hidden from the user is captured as
/// nothing, so "in the video but not on screen" is impossible that way. The
/// engine therefore composites this state into each frame's pixel buffer
/// before encoding, and the user's own screen stays clean.
///
/// Threading: input is observed on the main actor and published through
/// `InputOverlaySource`; the capture queue reads snapshots from it.
@MainActor
final class InputOverlayController {
    /// Handed to the engine when any visualization is enabled.
    let source = InputOverlaySource()

    private let monitor = InputMonitor()
    private var timer: Timer?
    private var state = InputVisualState()

    /// Starts observing. Returns nil when nothing is enabled, so recording
    /// pays no cost at all in the common case.
    @discardableResult
    func start() -> InputOverlaySource? {
        stop()
        state = InputVisualState()
        state.doubleCursor = Prefs.showsCursor && Prefs.doubleCursorSize
        state.showsClicks = Prefs.showsMouseClicks
        state.showsScroll = Prefs.showsMouseScroll
        state.showsKeyboard = Prefs.showsKeyStrokes
        state.showsCombos = Prefs.showsKeyCombinations
        guard state.isEnabled else { return nil }
        state.mouse = NSEvent.mouseLocation

        monitor.onButton = { [weak self] button, isDown in
            guard let self else { return }
            if isDown { state.buttons.insert(button.rawValue) }
            else { state.buttons.remove(button.rawValue) }
            publish()
        }
        monitor.onScroll = { [weak self] delta in
            guard let self else { return }
            // 12° per line keeps the wheel's rotation legible rather than a blur.
            state.scrollAngle -= delta * 12
            state.lastScroll = CACurrentMediaTime()
            publish()
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
            if state.showsCombos, modifiers.contains(where: { $0 != "⇧" }) {
                state.combo = InputVisualState.ComboHit(chips: modifiers + [label],
                                                        time: now)
            }
            publish()
        }
        monitor.start(wantsMouse: state.showsClicks || state.showsScroll || state.doubleCursor,
                      wantsKeys: state.showsKeyboard || state.showsCombos)

        // Tracks the pointer and ages out every fade. 60 Hz is cheap here —
        // it only mutates state; the drawing happens per captured frame.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.current.add(timer, forMode: .common)
        self.timer = timer
        publish()
        return source
    }

    func stop() {
        monitor.stop()
        monitor.onButton = nil
        monitor.onScroll = nil
        monitor.onKey = nil
        timer?.invalidate()
        timer = nil
        state = InputVisualState()
        source.publish(state)
    }

    private func tick() {
        let now = CACurrentMediaTime()
        if state.doubleCursor || state.showsClicks || state.showsScroll {
            state.mouse = NSEvent.mouseLocation
            if state.doubleCursor {
                // The system cursor changes shape over text fields, links, …
                // and may only be read from the main thread, hence here.
                let cursor = NSCursor.currentSystem
                state.cursorImage = cursor?.image
                state.cursorHotSpot = cursor?.hotSpot ?? .zero
            }
        }
        state.keys.removeAll { now - $0.time >= InputVisualState.keyboardLinger }
        if state.keys.isEmpty { state.lastKey = nil }
        if let combo = state.combo, now - combo.time > InputVisualState.comboLinger {
            state.combo = nil
        }
        if let scroll = state.lastScroll, now - scroll > InputVisualState.scrollLinger {
            state.lastScroll = nil
        }
        publish()
    }

    private func publish() { source.publish(state) }
}

// MARK: - Hand-off to the capture queue

/// Carries the visualization state from the main actor to the capture queue.
/// `@unchecked Sendable` is backed by the lock: the state is only ever copied
/// in and out under it, and its one reference type (the cursor image) is
/// immutable once captured.
final class InputOverlaySource: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: InputVisualState())

    func publish(_ state: InputVisualState) { lock.withLock { $0 = state } }
    func snapshot() -> InputVisualState { lock.withLock { $0 } }
}

// MARK: - Visual state

/// Everything to draw, in global (AppKit, bottom-left origin) coordinates.
///
/// `@unchecked Sendable`: a value type whose only reference is the cursor
/// image, captured once on the main actor and thereafter only read. Required
/// because it crosses to the capture queue inside a lock (whose state must be
/// Sendable) — the older SDK on CI enforces this where the newer one does not.
struct InputVisualState: @unchecked Sendable {
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

    var isEnabled: Bool {
        doubleCursor || showsClicks || showsScroll || showsKeyboard || showsCombos
    }

    /// Whether this snapshot would draw anything at all — lets the compositor
    /// skip untouched frames entirely.
    var hasContent: Bool {
        guard isEnabled else { return false }
        if doubleCursor, cursorImage != nil { return true }
        if showsClicks, !buttons.isEmpty { return true }
        if showsScroll, lastScroll != nil { return true }
        if showsKeyboard, !keys.isEmpty { return true }
        if showsCombos, combo != nil { return true }
        return false
    }
}

// MARK: - Compositing into captured frames

enum InputOverlayCompositor {
    /// Draws `state` into a BGRA pixel buffer. `area` is the global AppKit
    /// rect the frame covers, so the context can be set up in screen
    /// coordinates and every drawing routine below stays in one space.
    static func composite(_ state: InputVisualState, area: NSRect,
                          into pixelBuffer: CVPixelBuffer) {
        guard state.hasContent, area.width > 0, area.height > 0 else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let context = CGContext(
            data: base, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }

        context.saveGState()
        // A bitmap context's origin is the bottom-left of the image, which is
        // also AppKit's convention — so no vertical flip is needed, only the
        // screen-points → frame-pixels mapping.
        context.scaleBy(x: CGFloat(width) / area.width, y: CGFloat(height) / area.height)
        context.translateBy(x: -area.minX, y: -area.minY)

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        InputOverlayRenderer.draw(state, area: area)
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }
}

// MARK: - Drawing

/// All drawing happens in global AppKit coordinates; the compositor has
/// already mapped the context onto the captured area.
enum InputOverlayRenderer {
    static func draw(_ state: InputVisualState, area: NSRect) {
        let now = CACurrentMediaTime()

        if state.showsScroll, let last = state.lastScroll {
            let alpha = 1 - min(1, (now - last) / InputVisualState.scrollLinger)
            drawWheel(at: NSPoint(x: state.mouse.x + 46, y: state.mouse.y),
                      angle: state.scrollAngle, alpha: alpha, highlighted: false)
        }
        if state.showsClicks, !state.buttons.isEmpty {
            drawClickRing(at: state.mouse, buttons: state.buttons)
        }
        if state.doubleCursor, let image = state.cursorImage {
            drawDoubledCursor(image, hotSpot: state.cursorHotSpot, at: state.mouse)
        }

        var keyboardShown = false
        if state.showsKeyboard, !state.keys.isEmpty, let lastKey = state.lastKey {
            let age = now - lastKey
            let fade = age > InputVisualState.keyboardLinger - 0.4
                ? max(0, (InputVisualState.keyboardLinger - age) / 0.4)
                : 1
            drawKeyboard(state, area: area, alpha: fade, now: now)
            keyboardShown = true
        }
        if state.showsCombos, let combo = state.combo {
            let age = now - combo.time
            let fade = age > InputVisualState.comboLinger - 0.35
                ? max(0, (InputVisualState.comboLinger - age) / 0.35)
                : 1
            drawCombo(combo, area: area, alpha: fade, aboveKeyboard: keyboardShown)
        }
    }

    // MARK: Mouse

    /// Ring around the pointer: the left half lights up for a left click, the
    /// right half for a right click, and a wheel glyph in the middle for the
    /// middle button.
    private static func drawClickRing(at point: NSPoint, buttons: Set<Int>) {
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
            drawWheel(at: point, angle: 0, alpha: 1, highlighted: true)
        }
    }

    private static func fillHalf(at center: NSPoint, radius: CGFloat,
                                 left: Bool, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: center)
        // Counterclockwise: 90→270 sweeps through 180° (left), 270→90 through 0°.
        path.appendArc(withCenter: center, radius: radius,
                       startAngle: left ? 90 : 270,
                       endAngle: left ? 270 : 90)
        path.close()
        color.setFill()
        path.fill()
    }

    /// Side view of a mouse wheel; `angle` scrolls its ticks.
    private static func drawWheel(at center: NSPoint, angle: Double,
                                  alpha: Double, highlighted: Bool) {
        let size = NSSize(width: 13, height: 20)
        let body = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                          width: size.width, height: size.height)
        let path = NSBezierPath(roundedRect: body,
                                xRadius: size.width / 2, yRadius: size.width / 2)
        (highlighted ? NSColor.systemBlue : NSColor.black)
            .withAlphaComponent((highlighted ? 0.85 : 0.55) * alpha).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.95 * alpha).setStroke()
        path.lineWidth = 1.5
        path.stroke()

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

    /// A 2× copy of the live cursor, anchored so its hot spot sits on the real
    /// pointer position. Cursor images are top-left-origin, hence the flip.
    private static func drawDoubledCursor(_ image: NSImage, hotSpot: NSPoint,
                                          at point: NSPoint) {
        let scaled = NSSize(width: image.size.width * 2, height: image.size.height * 2)
        let origin = NSPoint(x: point.x - hotSpot.x * 2,
                             y: point.y + hotSpot.y * 2 - scaled.height)
        image.draw(in: NSRect(origin: origin, size: scaled),
                   from: .zero, operation: .sourceOver, fraction: 1)
    }

    // MARK: Keyboard

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

    /// Centred in the captured area.
    private static func keyboardFrame(in area: NSRect) -> NSRect {
        let width = rows.map(rowWidth).max() ?? 0
        let height = CGFloat(rows.count) * keyUnit + CGFloat(rows.count - 1) * keyGap
        let padding: CGFloat = 12
        return NSRect(x: area.midX - (width + padding * 2) / 2,
                      y: area.midY - (height + padding * 2) / 2,
                      width: width + padding * 2,
                      height: height + padding * 2)
    }

    private static func drawKeyboard(_ state: InputVisualState, area: NSRect,
                                     alpha: Double, now: CFTimeInterval) {
        let frame = keyboardFrame(in: area)
        let body = NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12)
        NSColor.black.withAlphaComponent(0.55 * alpha).setFill()
        body.fill()
        NSColor.white.withAlphaComponent(0.18 * alpha).setStroke()
        body.lineWidth = 1
        body.stroke()

        let lit = Set(state.keys
            .filter { now - $0.time < InputVisualState.keyHighlight }
            .map { $0.label.lowercased() })

        var y = frame.maxY - 12 - keyUnit
        for row in rows {
            var x = frame.midX - rowWidth(row) / 2
            for (label, widthUnits) in row {
                let width = widthUnits * keyUnit
                let keyRect = NSRect(x: x, y: y, width: width, height: keyUnit)
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
                x += width + keyGap
            }
            y -= keyUnit + keyGap
        }
    }

    /// Chips sit above the keyboard when it is showing, so the two never
    /// overlap; centred on their own otherwise.
    private static func drawCombo(_ combo: InputVisualState.ComboHit, area: NSRect,
                                  alpha: Double, aboveKeyboard: Bool) {
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

        let y = aboveKeyboard
            ? keyboardFrame(in: area).maxY + 14
            : area.midY - height / 2
        var x = area.midX - total / 2

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
