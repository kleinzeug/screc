import AppKit

/// Approximates "the focused window" without requiring the Accessibility
/// permission: the frontmost application's top layer-0 window in z-order.
/// Stay-on-top tool windows live on higher CGWindow layers, so they never
/// win. Polls, because macOS offers no cross-app window-move notifications
/// without AX.
@MainActor
final class FocusedWindowTracker {
    private var timer: Timer?
    private var currentWindowID: CGWindowID = 0
    private var lastFrame: NSRect = .zero
    private var scanCountdown = 0
    private var onFrame: ((NSRect) -> Void)?
    private var onWindowChange: ((CGWindowID) -> Void)?

    func start(initialWindowID: CGWindowID,
               onFrame: @escaping (NSRect) -> Void,
               onWindowChange: @escaping (CGWindowID) -> Void) {
        stop()
        currentWindowID = initialWindowID
        lastFrame = .zero
        self.onFrame = onFrame
        self.onWindowChange = onWindowChange
        // 30 Hz keeps the passe-partout visually glued to the window; a
        // window-list query is a fraction of a millisecond.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onFrame = nil
        onWindowChange = nil
    }

    /// Split cadence (measured: full window list ≈ 1.5 ms, single-window
    /// description ≈ 0.1 ms): the followed window's frame is tracked at the
    /// full 30 Hz via the cheap query; the full-list scan that detects focus
    /// CHANGES runs at ~5 Hz — a focus switch doesn't need 33 ms latency.
    private func tick() {
        scanCountdown -= 1
        if scanCountdown <= 0 {
            scanCountdown = 6
            // nil (e.g. our own app is active, or the front app has no plain
            // window) keeps the current target — recording continues unchanged.
            if let info = Self.focusedWindowInfo() {
                if info.id != currentWindowID {
                    currentWindowID = info.id
                    onWindowChange?(info.id)
                }
                if info.frame != lastFrame {
                    lastFrame = info.frame
                    onFrame?(info.frame)
                }
                return
            }
        }
        guard currentWindowID != 0,
              let frame = PinnedWindowTracker.frame(of: currentWindowID),
              frame != lastFrame
        else { return }
        lastFrame = frame
        onFrame?(frame)
    }

    static func focusedWindowInfo() -> (id: CGWindowID, frame: NSRect)? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let list = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let pid = Int(front.processIdentifier)
        for info in list { // front-to-back
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int) == pid,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let cgRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  cgRect.width > 40, cgRect.height > 40
            else { continue }
            return (CGWindowID(number), appKitRect(fromCG: cgRect))
        }
        return nil
    }

    /// CG global coordinates are top-left-origin anchored at the primary
    /// display; AppKit's are bottom-left-origin at the same anchor.
    static func appKitRect(fromCG rect: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY,
                      width: rect.width, height: rect.height)
    }
}
