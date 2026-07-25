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

    func begin(onCommit: @escaping (CGDirectDisplayID, CGRect) -> Void,
               onCancel: @escaping () -> Void) {
        dismiss()
        self.onCommit = onCommit
        self.onCancel = onCancel

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
    }

    func dismiss() {
        recPanel?.close()
        recPanel = nil
        windows.forEach { $0.close() }
        windows = []
        currentSelection = nil
        onCommit = nil
        onCancel = nil
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
        showRecPanel(for: rect, on: screen)
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

    func clearSelection() {
        selection = nil
        creationStart = nil
        adjustDrag = nil
        lastDragPoint = nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onDragBegan?()
        if let selection, let mode = RectDrag.hitTest(point: point, rect: selection) {
            adjustDrag = RectDrag(mode: mode, startRect: selection, startPoint: point)
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
            selection = nil // too small — treat as a stray click, keep selecting
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
        // Punch the selection out of the dim layer.
        NSColor.clear.setFill()
        rect.fill(using: .copy)

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
