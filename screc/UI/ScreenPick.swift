import AppKit

/// Display picker, used when a remembered display is gone or the screen
/// arrangement changed: the screen under the pointer gets a highlighted
/// boundary, and a click selects it and starts recording.
@MainActor
final class ScreenPickController {
    private var windows: [ScreenPickWindow] = []
    private var onCommit: ((CGDirectDisplayID) -> Void)?
    private var onCancel: (() -> Void)?

    func begin(onCommit: @escaping (CGDirectDisplayID) -> Void,
               onCancel: @escaping () -> Void) {
        dismiss()
        self.onCommit = onCommit
        self.onCancel = onCancel
        for screen in NSScreen.screens {
            let window = ScreenPickWindow(screen: screen, controller: self)
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
        updateHover()
    }

    func dismiss() {
        windows.forEach { $0.close() }
        windows = []
        onCommit = nil
        onCancel = nil
        NSCursor.arrow.set()
    }

    func updateHover() {
        let mouse = NSEvent.mouseLocation
        for window in windows {
            window.pickView.isHot = NSMouseInRect(mouse, window.targetScreen.frame, false)
        }
    }

    func select(_ displayID: CGDirectDisplayID) {
        let handler = onCommit
        dismiss()
        handler?(displayID)
    }

    func cancel() {
        let handler = onCancel
        dismiss()
        handler?()
    }
}

private final class ScreenPickWindow: NSWindow {
    let targetScreen: NSScreen
    let pickView: ScreenPickView

    init(screen: NSScreen, controller: ScreenPickController) {
        self.targetScreen = screen
        self.pickView = ScreenPickView(controller: controller,
                                       displayID: screen.displayID,
                                       screenName: screen.localizedName)
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

private final class ScreenPickView: NSView {
    weak var controller: ScreenPickController?
    private let displayID: CGDirectDisplayID
    private let screenName: String

    var isHot = false {
        didSet { if isHot != oldValue { needsDisplay = true } }
    }

    init(controller: ScreenPickController, displayID: CGDirectDisplayID, screenName: String) {
        self.controller = controller
        self.displayID = displayID
        self.screenName = screenName
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited,
                                                 .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: WindowPickController.cameraCursor)
    }

    override func mouseMoved(with event: NSEvent) { controller?.updateHover() }
    override func mouseEntered(with event: NSEvent) { controller?.updateHover() }
    override func mouseExited(with event: NSEvent) { controller?.updateHover() }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
    }

    override func mouseUp(with event: NSEvent) {
        controller?.select(displayID)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { controller?.cancel() } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(isHot ? 0.18 : 0.42).setFill()
        bounds.fill()

        if isHot {
            let inset = bounds.insetBy(dx: 6, dy: 6)
            NSColor.systemBlue.setStroke()
            let border = NSBezierPath(roundedRect: inset, xRadius: 14, yRadius: 14)
            border.lineWidth = 8
            border.stroke()
        }

        let text = isHot ? "Click to record \(screenName)" : screenName
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: isHot ? 22 : 17, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(isHot ? 0.95 : 0.6),
        ]
        let size = text.size(withAttributes: attributes)
        let origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        let plate = NSRect(x: origin.x - 20, y: origin.y - 12,
                           width: size.width + 40, height: size.height + 24)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: plate, xRadius: 12, yRadius: 12).fill()
        text.draw(at: origin, withAttributes: attributes)
    }
}
