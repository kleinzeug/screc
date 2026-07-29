import AppKit
import SwiftUI

/// Region drag-select: one borderless overlay window per screen dims
/// everything; the user drags a rectangle, then can adjust it (edges,
/// corners, move; ⌥ mirror, ⇧ aspect lock) before confirming via the
/// floating REC panel or Enter. Esc cancels; a drag outside the selection
/// starts a new one. The overlay intercepts all clicks until REC — only the
/// recording passe-partout that follows is click-through. Every window here
/// sets `sharingType = .none` so none of it can appear in a recording.
///
/// The committed rect is display-local, top-left origin, in points — exactly
/// what `SCStreamConfiguration.sourceRect` expects (AppKit rects are
/// bottom-left origin, hence the Y flip on commit).
@MainActor
final class RegionSelectionController {
    private var windows: [SelectionWindow] = []
    private var recPanel: NSPanel?
    private var currentSelection: (screen: NSScreen, rect: NSRect)?
    private var onCommit: ((CGDirectDisplayID, CGRect) -> Void)?
    private var onCancel: (() -> Void)?
    /// Fired whenever the rect changes, so the region survives a cancelled
    /// pick — you drew it, so it is remembered either way.
    private var onRegionChanged: ((CGDirectDisplayID, CGRect) -> Void)?

    /// `preload` is a display-local, top-left-origin rect (sourceRect
    /// convention) to reopen with — the region the mode last recorded.
    func begin(preload: (CGDirectDisplayID, CGRect)? = nil,
               onRegionChanged: @escaping (CGDirectDisplayID, CGRect) -> Void = { _, _ in },
               onCommit: @escaping (CGDirectDisplayID, CGRect) -> Void,
               onCancel: @escaping () -> Void) {
        dismiss()
        self.onCommit = onCommit
        self.onCancel = onCancel
        self.onRegionChanged = onRegionChanged

        let forcedAspect = PresetLibrary.currentConfig.aspectValue
        for screen in NSScreen.screens {
            let window = SelectionWindow(screen: screen)
            window.selectionView.forcedAspect = forcedAspect
            window.selectionView.onDragBegan = { [weak self] in
                self?.dragBegan(on: window)
            }
            window.selectionView.onSelectionChanged = { [weak self] rect in
                self?.selectionChanged(on: screen, rect: rect)
            }
            window.selectionView.onCommit = { [weak self] in self?.commit() }
            window.selectionView.onCancel = { [weak self] in self?.cancel() }
            // Reopen on the remembered rect (converted back to AppKit's
            // bottom-left origin) so it can simply be confirmed or nudged.
            if let preload, preload.0 == screen.displayID {
                let local = NSRect(x: preload.1.minX,
                                   y: screen.frame.height - preload.1.maxY,
                                   width: preload.1.width, height: preload.1.height)
                window.selectionView.setSelection(local)
                currentSelection = (screen, local)
            }
            windows.append(window)
        }
        // The overlay needs key status for Esc/Enter; accessory apps can
        // activate. Key goes to the screen under the mouse.
        NSApp.activate()
        let mouse = NSEvent.mouseLocation
        for window in windows {
            if NSMouseInRect(mouse, window.targetScreen.frame, false) {
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFrontRegardless()
            }
        }
        if let (screen, rect) = currentSelection {
            showRecPanel(for: rect, on: screen)
        }
    }

    func dismiss() {
        recPanel?.close()
        recPanel = nil
        windows.forEach { $0.close() }
        windows = []
        currentSelection = nil
        onCommit = nil
        onCancel = nil
        onRegionChanged = nil
    }

    // MARK: - Selection flow

    private func dragBegan(on window: SelectionWindow) {
        recPanel?.close()
        recPanel = nil
        window.makeKeyAndOrderFront(nil)
        for other in windows where other !== window {
            other.selectionView.clearSelection()
        }
    }

    /// Called on drag end — both after the initial placement and after every
    /// adjustment.
    private func selectionChanged(on screen: NSScreen, rect: NSRect) {
        currentSelection = (screen, rect)
        onRegionChanged?(screen.displayID, Self.displayLocal(rect, on: screen))
        showRecPanel(for: rect, on: screen)
    }

    /// AppKit bottom-left origin → SCK top-left origin, display-local.
    private static func displayLocal(_ rect: NSRect, on screen: NSScreen) -> CGRect {
        CGRect(x: rect.minX, y: screen.frame.height - rect.maxY,
               width: rect.width, height: rect.height)
    }

    private func commit() {
        guard let (screen, rect) = currentSelection else { return }
        let displayID = screen.displayID
        // AppKit bottom-left origin → SCK top-left origin, display-local points.
        let local = CGRect(x: rect.minX,
                           y: screen.frame.height - rect.maxY,
                           width: rect.width,
                           height: rect.height)
        let handler = onCommit
        dismiss()
        handler?(displayID, local)
    }

    private func cancel() {
        let handler = onCancel
        dismiss()
        handler?()
    }

    // MARK: - REC panel

    private func showRecPanel(for rect: NSRect, on screen: NSScreen) {
        recPanel?.close()
        let panel = RecPanel.make(
            width: Int(rect.width), height: Int(rect.height),
            onRecord: { [weak self] in self?.commit() },
            onCancel: { [weak self] in self?.cancel() })
        let global = NSRect(x: screen.frame.minX + rect.minX,
                            y: screen.frame.minY + rect.minY,
                            width: rect.width, height: rect.height)
        RecPanel.position(panel, below: global, on: screen)
        recPanel = panel
    }
}

// MARK: - Overlay window

private final class SelectionWindow: NSWindow {
    let targetScreen: NSScreen
    let selectionView = SelectionView()

    init(screen: NSScreen) {
        self.targetScreen = screen
        super.init(contentRect: screen.frame, styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        sharingType = .none
        isReleasedWhenClosed = false
        contentView = selectionView
        makeFirstResponder(selectionView)
    }

    // Borderless windows refuse key status by default; Esc/Enter need it.
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        selectionView.onCancel?()
    }
}

// MARK: - Overlay view

private final class SelectionView: NSView {
    var onDragBegan: (() -> Void)?
    /// Fired on drag end with the final rect (placement or adjustment).
    var onSelectionChanged: ((NSRect) -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    /// "Force Aspect Ratio" setting: width ÷ height, or nil.
    var forcedAspect: Double?

    private var creationStart: NSPoint?
    private var adjustDrag: RectDrag?
    private var lastDragPoint: NSPoint?
    private var selection: NSRect? {
        didSet { needsDisplay = true }
    }

    private var isDragging: Bool { creationStart != nil || adjustDrag != nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setSelection(_ rect: NSRect) {
        selection = rect
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    /// Cursor follows what a drag would do at this point: resize on the
    /// edges and corners, move inside, crosshair everywhere else.
    override func mouseMoved(with event: NSEvent) {
        guard !isDragging else { return }
        cursor(for: convert(event.locationInWindow, from: nil)).set()
    }

    private func cursor(for point: NSPoint) -> NSCursor {
        guard let selection, let mode = RectDrag.hitTest(point: point, rect: selection)
        else { return .crosshair }
        switch mode {
        case .move:
            return .openHand
        case .resize(let ex, let ey):
            if ex != 0 && ey != 0 {
                return RegionCursors.corner(ex: ex, ey: ey)
            }
            return ex != 0 ? .resizeLeftRight : .resizeUpDown
    }
    }

    func clearSelection() {
        selection = nil
        creationStart = nil
        adjustDrag = nil
        lastDragPoint = nil
    }

    override func resetCursorRects() {
        if selection == nil {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onDragBegan?()
        if let selection, let mode = RectDrag.hitTest(point: point, rect: selection) {
            adjustDrag = RectDrag(mode: mode, startRect: selection, startPoint: point)
            if case .move = mode { NSCursor.closedHand.set() }
        } else {
            // Outside the existing selection: start a fresh one.
            creationStart = point
            selection = nil
        }
        lastDragPoint = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastDragPoint = point
        if let drag = adjustDrag {
            // Forced aspect behaves like a permanently held ⇧ (the start rect
            // already carries the forced ratio from creation).
            let modifiers = forcedAspect != nil
                ? event.modifierFlags.union(.shift)
                : event.modifierFlags
            selection = drag.rect(at: point, modifiers: modifiers, bounds: bounds)
        } else if let start = creationStart {
            var width = abs(point.x - start.x)
            var height = abs(point.y - start.y)
            if let aspect = forcedAspect {
                // Dominant axis wins; anchor at the drag start.
                if width / aspect >= height {
                    height = width / aspect
                } else {
                    width = height * aspect
                }
            }
            selection = NSRect(x: point.x >= start.x ? start.x : start.x - width,
                               y: point.y >= start.y ? start.y : start.y - height,
                               width: width,
                               height: height).integral
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            creationStart = nil
            adjustDrag = nil
            lastDragPoint = nil
            needsDisplay = true
        }
        if adjustDrag != nil {
            if let rect = selection {
                onSelectionChanged?(rect)
            }
            return
        }
        guard let rect = selection, rect.width >= 10, rect.height >= 10 else {
            // A click rather than a drag: start from the whole screen, which
            // can then be resized down. With Force Aspect Ratio on, use the
            // largest centered rect of that ratio instead of the raw bounds.
            var whole = bounds.integral
            if let aspect = forcedAspect, aspect > 0 {
                var width = bounds.width
                var height = width / aspect
                if height > bounds.height {
                    height = bounds.height
                    width = height * aspect
                }
                whole = NSRect(x: bounds.midX - width / 2,
                               y: bounds.midY - height / 2,
                               width: width, height: height).integral
            }
            selection = whole
            onSelectionChanged?(whole)
            return
        }
        onSelectionChanged?(rect)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc (also covered by cancelOperation)
            onCancel?()
        case 36, 76: // Return / Enter confirm an existing selection
            if selection != nil { onCommit?() }
        default:
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()

        guard let rect = selection else {
            drawHint()
            return
        }
        // Punch the selection out of the dim layer, then lay an almost
        // invisible film back over it: a fully transparent pixel makes the
        // window pass clicks through to whatever is behind, so dragging
        // inside the region would hit the app underneath instead of moving
        // the region.
        NSColor.clear.setFill()
        rect.fill(using: .copy)
        NSColor.white.withAlphaComponent(0.005).setFill()
        rect.fill()

        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()

        if !isDragging {
            AdjustChrome.drawHandles(for: rect)
        }
        if isDragging, let mouse = lastDragPoint {
            AdjustChrome.drawSizeLabel(centeredIn: rect)
            let mode = adjustDrag?.mode ?? .resize(ex: 1, ey: 1)
            AdjustChrome.drawCoordChip(mode: adjustDrag != nil ? mode : .move,
                                       rect: adjustDrag != nil ? rect : NSRect(origin: mouse, size: .zero),
                                       container: bounds, mouse: mouse,
                                       viewBounds: bounds)
        }
    }

    private func drawHint() {
        let text = "Drag to select the region to record   ·   Esc cancels"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.8),
        ]
        let size = text.size(withAttributes: attributes)
        let origin = NSPoint(x: bounds.midX - size.width / 2,
                             y: bounds.midY - size.height / 2)
        let background = NSRect(x: origin.x - 14, y: origin.y - 8,
                                width: size.width + 28, height: size.height + 16)
        NSColor.black.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: background, xRadius: 8, yRadius: 8).fill()
        text.draw(at: origin, withAttributes: attributes)
    }
}

// MARK: - Drawn cursors

/// AppKit ships no public corner-resize cursor, so draw L-shaped corner
/// brackets — one per corner, oriented like the corner it grabs.
@MainActor
enum RegionCursors {
    static let bottomLeft = corner(dx: -1, dy: -1)
    static let bottomRight = corner(dx: 1, dy: -1)
    static let topLeft = corner(dx: -1, dy: 1)
    static let topRight = corner(dx: 1, dy: 1)

    static func corner(ex: Int, ey: Int) -> NSCursor {
        switch (ex, ey) {
        case (-1, -1): return bottomLeft
        case (1, -1): return bottomRight
        case (-1, 1): return topLeft
        default: return topRight
        }
    }

    /// `dx`/`dy` point at the corner being grabbed, in AppKit's
    /// bottom-left-origin space; the bracket's arms run back inward.
    private static func corner(dx: CGFloat, dy: CGFloat) -> NSCursor {
        let side: CGFloat = 24
        let image = NSImage(size: NSSize(width: side, height: side),
                            flipped: false) { rect in
            let cx = rect.midX, cy = rect.midY
            let out: CGFloat = 6   // how far the vertex sits from centre
            let arm: CGFloat = 11  // arm length, running inward

            let vertex = NSPoint(x: cx + dx * out, y: cy + dy * out)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: vertex.x - dx * arm, y: vertex.y))
            path.line(to: vertex)
            path.line(to: NSPoint(x: vertex.x, y: vertex.y - dy * arm))
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            // White casing so it stays visible over any content.
            NSColor.white.setStroke()
            path.lineWidth = 6
            path.stroke()
            NSColor.black.setStroke()
            path.lineWidth = 2.6
            path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }
}
