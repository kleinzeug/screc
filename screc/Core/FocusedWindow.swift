import AppKit
@preconcurrency import ScreenCaptureKit

enum FocusedWindow {
    /// Finds the focused window: the frontmost application's top layer-0
    /// window. Absolute z-order alone would be wrong — an always-on-top
    /// utility window from another app could dominate it — so the frontmost
    /// app's windows are preferred, and elevated CGWindow layers (floating
    /// panels, overlays) are excluded entirely. Clicking our status item does
    /// not activate screc, so the frontmost app is the one the user works in.
    @MainActor
    static func find() async throws -> SCWindow {
        let content = try await SCShareableContent
            .excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let myPID = ProcessInfo.processInfo.processIdentifier
        let frontPID = NSWorkspace.shared.frontmostApplication
            .map { pid_t($0.processIdentifier) }

        // CGWindowList "on screen" order is front-to-back — the z-order oracle;
        // SCShareableContent.windows ordering is undocumented. Layer 0 is the
        // normal-window layer (drops menu-bar items, overlays, panels).
        let orderedIDs: [CGWindowID] =
            ((CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                         kCGNullWindowID) as? [[String: Any]]) ?? [])
            .compactMap { info in
                guard (info[kCGWindowLayer as String] as? Int) == 0,
                      let number = info[kCGWindowNumber as String] as? Int
                else { return nil }
                return CGWindowID(number)
            }

        let byID = Dictionary(content.windows.map { ($0.windowID, $0) },
                              uniquingKeysWith: { first, _ in first })
        let candidates = orderedIDs.compactMap { byID[$0] }.filter { window in
            window.windowLayer == 0
                && window.isOnScreen
                && window.frame.width > 40 && window.frame.height > 40
                && window.owningApplication?.processID != myPID
        }

        if let frontPID, frontPID != myPID,
           let match = candidates.first(where: { $0.owningApplication?.processID == frontPID }) {
            return match
        }
        // Fallback (frontmost app has no plain window): topmost normal window.
        if let first = candidates.first {
            return first
        }
        throw ScrecError.noWindowToRecord
    }
}
