import AppKit
import SwiftUI

/// Result of the "record specific window" picker.
struct PinnedSelection {
    var windowID: CGWindowID
    var ownerName: String
    var title: String
    /// Window frame in global AppKit coordinates at selection time.
    var frame: NSRect
    /// Recorded sub-area, normalized (0…1) within the window, top-left origin —
    /// tracks the window through moves and scales with resizes.
    var normalizedRect: CGRect
}

/// Screenshot-style window picker: hovering highlights the window under the
/// mouse in light translucent blue with a camera cursor; a single click locks
/// it, then the capture boundary (initially the full window) can be dragged
/// and resized within the window (edges, corners, move; ⌥ mirror, ⇧ aspect
/// lock) before confirming via the REC panel or Enter.
@MainActor
final class WindowPickController {
    private struct Adjust {
        var info: WindowHitTest.Info
        var rect: NSRect // global AppKit
    }

    private var windows: [PickOverlayWindow] = []
    private var recPanel: NSPanel?
    private var hovered: WindowHitTest.Info?
    private var adjust: Adjust?
    private var onCommit: ((PinnedSelection) -> Void)?
    private var onCancel: (() -> Void)?

    static let cameraCursor: NSCursor = {
        let size = NSSize(width: 28, height: 28)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.withAlphaComponent(0.95).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            NSColor.black.withAlphaComponent(0.2).setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).stroke()
            if let symbol = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) {
                let s = symbol.size
                symbol.draw(at: NSPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2),
                            from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 14, y: 14))
    }()

    func begin(onCommit: @escaping (PinnedSelection) -> Void,
               onCancel: @escaping () -> Void) {
        dismiss()
        self.onCommit = onCommit
        self.onCancel = onCancel
        for screen in NSScreen.screens {
            let window = PickOverlayWindow(screen: screen, controller: self)
            windows.append(window)
        }
        NSApp.activate()
        let mouse = NSEvent.mouseLocation
        for window in windows {
            if NSMouseInRect(mouse, window.targetScreen.frame, false) {
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFrontRegardless()
            }
        }
        Self.cameraCursor.set()
        hoverMoved()
    }

    func dismiss() {
        recPanel?.close()
        recPanel = nil
        windows.forEach { $0.close() }
        windows = []
        hovered = nil
        adjust = nil
        onCommit = nil
        onCancel = nil
        NSCursor.arrow.set()
    }

    // MARK: - Called by the overlay views

    var isAdjusting: Bool { adjust != nil }

    func hoverMoved() {
        guard adjust == nil else { return }
        Self.cameraCursor.set()
        let found = WindowHitTest.window(at: NSEvent.mouseLocation)
        if found != hovered {
            hovered = found
            render()
        }
    }

    func clicked() {
        guard adjust == nil else { return }
        guard let hovered else { return }
        adjust = Adjust(info: hovered, rect: hovered.frame)
        NSCursor.arrow.set()
        render()
        presentPanel()
    }

    func adjustWindowRect() -> NSRect? { adjust?.info.frame }
    func adjustRect() -> NSRect? { adjust?.rect }

    func adjustChanged(to rect: NSRect) {
        adjust?.rect = rect
        render()
    }

    func adjustEnded() {
        presentPanel()
    }

    func commit() {
        guard let adjust else { return }
        let f = adjust.info.frame
        let r = adjust.rect
        let selection = PinnedSelection(
            windowID: adjust.info.id,
            ownerName: adjust.info.ownerName,
            title: adjust.info.title,
            frame: f,
            normalizedRect: CGRect(x: (r.minX - f.minX) / f.width,
                                   y: (f.maxY - r.maxY) / f.height,
                                   width: r.width / f.width,
                                   height: r.height / f.height))
        let handler = onCommit
        dismiss()
        handler?(selection)
    }

    func cancel() {
        let handler = onCancel
        dismiss()
        handler?()
    }

    // MARK: - Internals

    private func render() {
        for window in windows {
            window.pickView.hoverGlobal = adjust == nil ? hovered?.frame : nil
            window.pickView.hoverCoversGlobal = adjust == nil ? (hovered?.coveringFrames ?? []) : []
            window.pickView.adjustWindowGlobal = adjust?.info.frame
            window.pickView.adjustRectGlobal = adjust?.rect
        }
    }

    private func presentPanel() {
        recPanel?.close()
        guard let adjust,
              let screen = NSScreen.screens.first(where: {
                  $0.frame.intersects(adjust.rect)
              }) ?? NSScreen.main
        else { return }
        let panel = RecPanel.make(
            width: Int(adjust.rect.width), height: Int(adjust.rect.height),
            onRecord: { [weak self] in self?.commit() },
            onCancel: { [weak self] in self?.cancel() })
        RecPanel.position(panel, below: adjust.rect, on: screen)
        recPanel = panel
    }
}

// MARK: - Window hit testing

enum WindowHitTest {
    struct Info: Equatable {
        let id: CGWindowID
        let frame: NSRect // global AppKit
        let pid: Int
        let ownerName: String
        let title: String
        /// Frames of windows stacked in FRONT of this one that overlap it —
        /// the hover highlight is punched out there so it never paints over
        /// foreground windows (the capture itself still records the full
        /// window content, since pinned mode composites the window alone).
        let coveringFrames: [NSRect]
    }

    /// Front-to-back hit test over normal (layer 0) windows of other apps.
    @MainActor
    static func window(at point: NSPoint) -> Info? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cgPoint = CGPoint(x: point.x, y: primaryHeight - point.y)
        guard let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let myPid = Int(ProcessInfo.processInfo.processIdentifier)
        var inFront: [NSRect] = []
        for info in list { // front-to-back
            guard let pid = info[kCGWindowOwnerPID as String] as? Int, pid != myPid,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let cgRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            let frame = FocusedWindowTracker.appKitRect(fromCG: cgRect)
            let isCandidate = (info[kCGWindowLayer as String] as? Int) == 0
                && cgRect.width > 40 && cgRect.height > 40
            if isCandidate, cgRect.contains(cgPoint),
               let number = info[kCGWindowNumber as String] as? Int {
                return Info(id: CGWindowID(number),
                            frame: frame,
                            pid: pid,
                            ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
                            title: info[kCGWindowName as String] as? String ?? "",
                            coveringFrames: inFront.filter { $0.intersects(frame) })
            }
            inFront.append(frame)
        }
        return nil
    }
}

// MARK: - Overlay window & view

private final class PickOverlayWindow: NSWindow {
    let targetScreen: NSScreen
    let pickView: PickView

    init(screen: NSScreen, controller: WindowPickController) {
        self.targetScreen = screen
        self.pickView = PickView(controller: controller, screenFrame: screen.frame)
        super.init(contentRect: screen.frame, styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        sharingType = .none
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        contentView = pickView
        makeFirstResponder(pickView)
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        pickView.controller?.cancel()
    }
}

private final class PickView: NSView {
    weak var controller: WindowPickController?
    private let screenFrame: NSRect

    // Global-coordinate state pushed by the controller.
    var hoverGlobal: NSRect? { didSet { if hoverGlobal != oldValue { needsDisplay = true } } }
    var hoverCoversGlobal: [NSRect] = [] { didSet { if hoverCoversGlobal != oldValue { needsDisplay = true } } }
    var adjustWindowGlobal: NSRect? { didSet { if adjustWindowGlobal != oldValue { needsDisplay = true } } }
    var adjustRectGlobal: NSRect? { didSet { if adjustRectGlobal != oldValue { needsDisplay = true } } }

    private var activeDrag: RectDrag?
    private var lastDragPoint: NSPoint?

    init(controller: WindowPickController, screenFrame: NSRect) {
        self.controller = controller
        self.screenFrame = screenFrame
        super.init(frame: NSRect(origin: .zero, size: screenFrame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func toLocal(_ global: NSRect) -> NSRect {
        NSRect(x: global.minX - screenFrame.minX, y: global.minY - screenFrame.minY,
               width: global.width, height: global.height)
    }

    private func toGlobal(_ local: NSRect) -> NSRect {
        NSRect(x: local.minX + screenFrame.minX, y: local.minY + screenFrame.minY,
               width: local.width, height: local.height)
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        guard let controller else { return }
        if controller.isAdjusting, let rectGlobal = controller.adjustRect() {
            let point = convert(event.locationInWindow, from: nil)
            switch RectDrag.hitTest(point: point, rect: toLocal(rectGlobal)) {
            case .move: NSCursor.openHand.set()
            case .resize(let ex, let ey) where ex != 0 && ey != 0:
                RegionCursors.corner(ex: ex, ey: ey).set()
            case .resize(let ex, _): (ex != 0 ? NSCursor.resizeLeftRight : .resizeUpDown).set()
            case nil: NSCursor.arrow.set()
            }
            return
        }
        controller.hoverMoved()
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller, controller.isAdjusting,
              let rectGlobal = controller.adjustRect()
        else { return }
        window?.makeKey()
        let point = convert(event.locationInWindow, from: nil)
        let rect = toLocal(rectGlobal)
        guard let mode = RectDrag.hitTest(point: point, rect: rect) else { return }
        activeDrag = RectDrag(mode: mode, startRect: rect, startPoint: point)
        lastDragPoint = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let controller, controller.isAdjusting,
              let windowGlobal = controller.adjustWindowRect(),
              let activeDrag
        else { return }
        let point = convert(event.locationInWindow, from: nil)
        lastDragPoint = point
        let rect = activeDrag.rect(at: point, modifiers: event.modifierFlags,
                             bounds: toLocal(windowGlobal))
        controller.adjustChanged(to: toGlobal(rect))
    }

    override func mouseUp(with event: NSEvent) {
        guard let controller else { return }
        if controller.isAdjusting {
            if activeDrag != nil {
                activeDrag = nil
                lastDragPoint = nil
                needsDisplay = true
                controller.adjustEnded()
            }
        } else {
            controller.clicked()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc (also covered by cancelOperation)
            controller?.cancel()
        case 36, 76: // Return / Enter
            if controller?.isAdjusting == true { controller?.commit() }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if let adjustWindowGlobal, let adjustRectGlobal {
            // Adjust phase: dim everything, punch out the capture rect,
            // draw border + resize handles (+ drag labels).
            NSColor.black.withAlphaComponent(0.3).setFill()
            bounds.fill()
            let rect = toLocal(adjustRectGlobal)
            let windowRect = toLocal(adjustWindowGlobal)
            guard rect.intersects(bounds) || windowRect.intersects(bounds)
            else { return }
            NSColor.clear.setFill()
            rect.fill(using: .copy)
            // Fully transparent pixels let clicks through the window, which
            // would break dragging the capture rect — keep a trace of alpha.
            NSColor.white.withAlphaComponent(0.005).setFill()
            rect.fill()
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let border = NSBezierPath(rect: rect.insetBy(dx: -0.75, dy: -0.75))
            border.lineWidth = 1.5
            border.stroke()
            if activeDrag == nil {
                AdjustChrome.drawHandles(for: rect)
            }
            if let activeDrag, let mouse = lastDragPoint {
                AdjustChrome.drawSizeLabel(centeredIn: rect)
                AdjustChrome.drawCoordChip(mode: activeDrag.mode, rect: rect,
                                           container: windowRect, mouse: mouse,
                                           viewBounds: bounds)
            }
        } else if let hoverGlobal {
            // Hover phase: light blue highlight over the window under the
            // mouse (screenshot-picker style), no global dim.
            let rect = toLocal(hoverGlobal)
            guard rect.intersects(bounds) else { return }
            NSColor(calibratedRed: 0.6, green: 0.8, blue: 1.0, alpha: 0.22).setFill()
            rect.fill()
            NSColor.systemBlue.withAlphaComponent(0.5).setStroke()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = 2
            border.stroke()
            // Punch out foreground windows overlapping the hovered one, so
            // the highlight never paints over what's visually in front.
            NSColor.clear.setFill()
            let paintedArea = rect.insetBy(dx: -2, dy: -2)
            for cover in hoverCoversGlobal {
                let local = toLocal(cover).intersection(paintedArea)
                if !local.isEmpty {
                    local.fill(using: .copy)
                }
            }
        }
    }
}
