import AppKit

/// Tracks one specific window for the "record specific window" mode. Unlike
/// the focus tracker this never follows focus: it watches a window ID, and
/// when that window disappears (closed, minimized, app quit) it reports
/// "gone" and keeps searching for a replacement — a window of the same app
/// (owner name, which survives process restarts) with the same title.
///
/// Known limitation (deliberate): if the window's TITLE changes while it is
/// gone (document renamed, browser tab switched), it is never re-found and
/// the recording stays paused until stopped manually — the stats readout
/// shows "paused" throughout. Auto-matching a *different* title would risk
/// silently recording the wrong content, which is worse than waiting.
@MainActor
final class PinnedWindowTracker {
    struct Identity {
        var ownerName: String
        var title: String
    }

    private var timer: Timer?
    private var currentWindowID: CGWindowID = 0
    private var identity = Identity(ownerName: "", title: "")
    private var lastFrame: NSRect = .zero
    private var alive = true
    private var searchCountdown = 0
    private var onFrame: ((NSRect) -> Void)?
    private var onGone: (() -> Void)?
    private var onReturn: ((CGWindowID, NSRect) -> Void)?

    func start(windowID: CGWindowID, identity: Identity,
               onFrame: @escaping (NSRect) -> Void,
               onGone: @escaping () -> Void,
               onReturn: @escaping (CGWindowID, NSRect) -> Void) {
        stop()
        self.currentWindowID = windowID
        self.identity = identity
        self.lastFrame = .zero
        self.alive = true
        self.onFrame = onFrame
        self.onGone = onGone
        self.onReturn = onReturn
        // 30 Hz while alive (single-window description query — very cheap)
        // keeps the passe-partout visually glued to the window.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onFrame = nil
        onGone = nil
        onReturn = nil
    }

    private func tick() {
        if let frame = Self.frame(of: currentWindowID) {
            if !alive { // came back on-screen under the same ID (e.g. unminimized)
                alive = true
                lastFrame = frame
                onReturn?(currentWindowID, frame)
                return
            }
            if frame != lastFrame {
                lastFrame = frame
                onFrame?(frame)
            }
            return
        }
        if alive {
            alive = false
            searchCountdown = 0
            onGone?()
        }
        // Identity search walks the full window list — throttle to ~3 Hz.
        searchCountdown -= 1
        guard searchCountdown <= 0 else { return }
        searchCountdown = 10
        if let found = Self.findWindow(matching: identity) {
            alive = true
            currentWindowID = found.id
            lastFrame = found.frame
            onReturn?(found.id, found.frame)
        }
    }

    /// Frame of a live, on-screen window; nil when closed or minimized.
    static func frame(of windowID: CGWindowID) -> NSRect? {
        guard let list = CGWindowListCreateDescriptionFromArray(
                  [NSNumber(value: windowID)] as CFArray) as? [[String: Any]],
              let info = list.first,
              (info[kCGWindowIsOnscreen as String] as? Bool) == true,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let cgRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { return nil }
        return FocusedWindowTracker.appKitRect(fromCG: cgRect)
    }

    /// Same app (owner name — survives a process restart) + same title.
    /// An empty stored title falls back to the app's frontmost plain window.
    static func findWindow(matching identity: Identity) -> (id: CGWindowID, frame: NSRect)? {
        guard let list = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        var ownerFallback: (id: CGWindowID, frame: NSRect)?
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerName as String] as? String) == identity.ownerName,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let cgRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  cgRect.width > 40, cgRect.height > 40
            else { continue }
            let frame = FocusedWindowTracker.appKitRect(fromCG: cgRect)
            let title = info[kCGWindowName as String] as? String ?? ""
            if title == identity.title {
                return (CGWindowID(number), frame)
            }
            if ownerFallback == nil {
                ownerFallback = (CGWindowID(number), frame)
            }
        }
        return identity.title.isEmpty ? ownerFallback : nil
    }
}
