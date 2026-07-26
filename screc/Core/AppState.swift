import AppKit
import Combine
import ScreenCaptureKit

struct RecordingStats: Equatable {
    var duration: TimeInterval = 0
    var bytesWritten: Int64 = 0
    var framesPerSecond: Double = 0
    var framesDropped: Int = 0
    /// Pinned mode: target window currently closed/minimized — waiting.
    var isPaused = false
}

/// Single source of truth for the app's lifecycle. Every UI surface (status
/// item, overlay windows, floating panel, menus) derives from `phase`.
@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Region drag-select or window-pick overlay is up.
        case selecting
        case recording
        /// Finalizing the file / converting.
        case finishing
    }

    enum CaptureRequest {
        case focusedWindow
        case display(CGDirectDisplayID)
        /// Rect is display-local, top-left origin, points (sourceRect convention).
        case region(CGDirectDisplayID, CGRect)
        case pinnedWindow(PinnedSelection)
    }

    /// The primary click repeats the last-used capture mode (persisted).
    enum DefaultCaptureMode: Equatable {
        case window
        case display(CGDirectDisplayID)
        case region(CGDirectDisplayID, CGRect)
        case pinned(ownerName: String, title: String, normalizedRect: CGRect)
    }

    @Published private(set) var phase: Phase = .idle {
        didSet { onChange?() }
    }
    @Published private(set) var stats = RecordingStats() {
        didSet { onChange?() }
    }
    /// Shown in the status item during `.finishing` ("saving…" / "converting…").
    @Published private(set) var finishingLabel = "saving…" {
        didSet { onChange?() }
    }
    private(set) var defaultMode: DefaultCaptureMode = .window {
        didSet {
            persistDefaultMode()
            onChange?()
        }
    }

    /// AppKit-side observer hook (the status item). SwiftUI views observe the
    /// `@Published` properties instead.
    var onChange: (() -> Void)?

    private let store: RecordingStore
    private var engine: ScreenRecorderEngine?
    private var isStarting = false
    /// Configuration the running recording was started with (drives GIF
    /// auto-convert).
    private var activeConfig: RecordingConfig?

    // Pinned-mode bookkeeping.
    private var currentPinned: PinnedSelection?
    private var currentPinnedDisplayID: CGDirectDisplayID = 0
    // The tracker ticks at 30 Hz; the passe-partout follows every tick, but
    // stream reconfigurations are coalesced to ~10 Hz (trailing edge wins).
    private var pendingPinnedSourceRect: CGRect?
    private var pinnedGeometryTimer: Timer?

    // Owned by the AppDelegate.
    weak var regionSelector: RegionSelectionController?
    weak var windowPicker: WindowPickController?
    weak var passepartout: PassepartoutController?
    weak var windowTracker: FocusedWindowTracker?
    weak var pinnedTracker: PinnedWindowTracker?

    init(store: RecordingStore) {
        self.store = store
        self.defaultMode = Self.loadDefaultMode()
    }

    // MARK: - Recording

    /// Primary click on the status item: repeat the last-used capture mode.
    func recordDefault() {
        switch defaultMode {
        case .window:
            record(.focusedWindow)
        case .display(let displayID):
            record(.display(displayID))
        case .region(let displayID, let rect):
            record(.region(displayID, rect))
        case .pinned(let ownerName, let title, let normalizedRect):
            let identity = PinnedWindowTracker.Identity(ownerName: ownerName, title: title)
            if let found = PinnedWindowTracker.findWindow(matching: identity) {
                record(.pinnedWindow(PinnedSelection(
                    windowID: found.id, ownerName: ownerName, title: title,
                    frame: found.frame, normalizedRect: normalizedRect)))
            } else {
                selectPinnedWindow() // window gone — fall back to the picker
            }
        }
    }

    func record(_ request: CaptureRequest) {
        guard phase == .idle, !isStarting else { return }
        isStarting = true
        defaultMode = Self.mode(for: request)
        Task {
            defer { isStarting = false }
            do {
                let target: CaptureTarget
                switch request {
                case .focusedWindow:
                    target = .window(try await FocusedWindow.find())
                case .display(let displayID):
                    target = .display(try await Self.display(withID: displayID))
                case .region(let displayID, let rect):
                    target = .region(try await Self.display(withID: displayID), rect)
                case .pinnedWindow(let selection):
                    target = try await Self.pinnedTarget(for: selection)
                    currentPinned = selection
                    currentPinnedDisplayID = Self.screenContaining(selection.frame)?.displayID ?? 0
                }
                try await begin(target: target)
            } catch {
                currentPinned = nil
                presentError(error)
            }
        }
    }

    func stopRecording() {
        guard phase == .recording, let engine else { return }
        windowTracker?.stop()
        pinnedTracker?.stop()
        passepartout?.hide()
        currentPinned = nil
        pinnedGeometryTimer?.invalidate()
        pinnedGeometryTimer = nil
        pendingPinnedSourceRect = nil
        phase = .finishing
        finishingLabel = "saving…"
        Task {
            do {
                let result = try await engine.stop()
                if Prefs.discardShortRecordings, result.duration < 3 {
                    // Accidental start-stop — not worth keeping.
                    try? FileManager.default.removeItem(at: result.url)
                } else if let config = activeConfig, config.format == .gif {
                    finishingLabel = "converting…"
                    let gifURL = Self.gifURL(for: result.url)
                    try await GIFConverter.convert(movie: result.url, to: gifURL,
                                                   maxWidth: config.maxWidth ?? 640,
                                                   fps: config.maxFPS,
                                                   loopForever: config.gifLoopForever,
                                                   dither: config.gifDitherIntensity)
                    try? FileManager.default.removeItem(at: result.url)
                    store.add(gifURL)
                    Notifier.recordingFinished(url: gifURL)
                } else {
                    store.add(result.url)
                    Notifier.recordingFinished(url: result.url)
                }
            } catch {
                presentError(error)
            }
            self.engine = nil
            self.activeConfig = nil
            self.stats = RecordingStats()
            self.phase = .idle
        }
    }

    /// "Convert to GIF" on a recent MP4 (⌥-click its recents entry). Uses the
    /// current config's GIF parameters when it is a GIF config, else defaults.
    func convertToGIF(_ movieURL: URL) {
        guard phase == .idle else { return }
        phase = .finishing
        finishingLabel = "converting…"
        let current = PresetLibrary.currentConfig
        let params = current.format == .gif
            ? (width: current.maxWidth ?? 640, fps: current.maxFPS,
               loop: current.gifLoopForever, dither: current.gifDitherIntensity)
            : (width: 640, fps: 12, loop: true, dither: 0)
        Task {
            do {
                let gifURL = Self.gifURL(for: movieURL)
                try await GIFConverter.convert(movie: movieURL, to: gifURL,
                                               maxWidth: params.width,
                                               fps: params.fps,
                                               loopForever: params.loop,
                                               dither: params.dither)
                store.add(gifURL)
            } catch {
                presentError(error)
            }
            self.phase = .idle
        }
    }

    private static func gifURL(for movieURL: URL) -> URL {
        let base = movieURL.deletingPathExtension()
        var url = base.appendingPathExtension("gif")
        if FileManager.default.fileExists(atPath: url.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            url = movieURL.deletingLastPathComponent()
                .appendingPathComponent("\(base.lastPathComponent)-\(stamp).gif")
        }
        return url
    }

    // MARK: - Selection flows

    func selectRegion() {
        guard phase == .idle, !isStarting, let regionSelector else { return }
        phase = .selecting
        regionSelector.begin(
            onCommit: { [weak self] displayID, rect in
                guard let self else { return }
                self.phase = .idle
                self.record(.region(displayID, rect))
            },
            onCancel: { [weak self] in
                self?.phase = .idle
            })
    }

    func selectPinnedWindow() {
        guard phase == .idle, !isStarting, let windowPicker else { return }
        phase = .selecting
        windowPicker.begin(
            onCommit: { [weak self] selection in
                guard let self else { return }
                self.phase = .idle
                self.record(.pinnedWindow(selection))
            },
            onCancel: { [weak self] in
                self?.phase = .idle
            })
    }

    func cancelSelection() {
        guard phase == .selecting else { return }
        regionSelector?.dismiss()
        windowPicker?.dismiss()
        phase = .idle
    }

    // MARK: - Internals

    private func begin(target: CaptureTarget) async throws {
        let config = PresetLibrary.currentConfig
        activeConfig = config
        let url = store.newOutputURL(fileExtension: "mp4")
        let engine = ScreenRecorderEngine(target: target, config: config, outputURL: url)
        engine.onStatsUpdate = { [weak self] stats in
            self?.stats = stats
        }
        // System tore the stream down (window closed in follow-focus mode,
        // stop via the system's capture indicator): run the normal stop path,
        // which finalizes the already-stopped stream's file — then explain
        // the reason unless the user did it deliberately.
        engine.onAutoStop = { [weak self] error in
            guard let self else { return }
            self.stopRecording()
            if let scError = error as? SCStreamError, scError.code == .userStopped {
                return // stopped via the system's capture indicator — normal
            }
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Recording was ended by the system"
            alert.informativeText = error.localizedDescription
                + "\n\nThe footage captured so far has been saved."
            alert.runModal()
        }
        try await engine.start()
        self.engine = engine
        phase = .recording
        presentIndicators(for: target)
    }

    /// The recording passe-partout: strongly dim everything except what's
    /// captured. Window mode follows focus; pinned mode follows one window
    /// through moves, closes and reopens.
    private func presentIndicators(for target: CaptureTarget) {
        switch target {
        case .display:
            break // whole screen is recorded; nothing to point out
        case .region(let display, let rect):
            if let hole = Self.globalRect(displayID: display.displayID, localTopLeft: rect) {
                passepartout?.show(hole: hole)
            }
        case .window(let window):
            let hole = FocusedWindowTracker.focusedWindowInfo()?.frame
            passepartout?.show(hole: hole)
            windowTracker?.start(
                initialWindowID: window.windowID,
                onFrame: { [weak self] frame in
                    self?.passepartout?.update(hole: frame)
                },
                onWindowChange: { [weak self] windowID in
                    self?.switchFocusRecording(to: windowID)
                })
        case .pinned(let window, _, _):
            guard let selection = currentPinned else { break }
            passepartout?.show(hole: Self.pinnedHole(windowFrame: selection.frame,
                                                     norm: selection.normalizedRect))
            pinnedTracker?.start(
                windowID: window.windowID,
                identity: .init(ownerName: selection.ownerName, title: selection.title),
                onFrame: { [weak self] frame in
                    self?.pinnedFrameChanged(frame)
                },
                onGone: { [weak self] in
                    self?.engine?.pause()
                    self?.passepartout?.update(hole: nil)
                },
                onReturn: { [weak self] windowID, frame in
                    self?.pinnedWindowReturned(windowID: windowID, frame: frame)
                })
        }
    }

    // MARK: Follow-focus (window mode)

    private func switchFocusRecording(to windowID: CGWindowID) {
        guard phase == .recording, let engine else { return }
        Task {
            guard let content = try? await SCShareableContent
                    .excludingDesktopWindows(true, onScreenWindowsOnly: true),
                  let window = content.windows.first(where: { $0.windowID == windowID })
            else { return }
            engine.switchToWindow(window)
        }
    }

    // MARK: Pinned mode

    private func pinnedFrameChanged(_ frame: NSRect) {
        guard phase == .recording, let engine, let selection = currentPinned else { return }
        currentPinned?.frame = frame
        let norm = selection.normalizedRect
        passepartout?.update(hole: Self.pinnedHole(windowFrame: frame, norm: norm))
        guard let screen = Self.screenContaining(frame) else { return }
        let sourceRect = Self.pinnedSourceRect(windowFrame: frame, norm: norm, screen: screen)
        if screen.displayID == currentPinnedDisplayID {
            schedulePinnedGeometry(sourceRect)
        } else {
            currentPinnedDisplayID = screen.displayID
            retargetPinned(sourceRect: sourceRect, resume: false)
        }
    }

    private func schedulePinnedGeometry(_ sourceRect: CGRect) {
        pendingPinnedSourceRect = sourceRect
        guard pinnedGeometryTimer == nil else { return }
        pinnedGeometryTimer = Timer.scheduledTimer(withTimeInterval: 0.1,
                                                   repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pinnedGeometryTimer = nil
                if let rect = self.pendingPinnedSourceRect, self.phase == .recording {
                    self.pendingPinnedSourceRect = nil
                    self.engine?.updatePinnedGeometry(sourceRect: rect)
                }
            }
        }
    }

    private func pinnedWindowReturned(windowID: CGWindowID, frame: NSRect) {
        guard phase == .recording, let selection = currentPinned else { return }
        currentPinned?.windowID = windowID
        currentPinned?.frame = frame
        guard let screen = Self.screenContaining(frame) else { return }
        currentPinnedDisplayID = screen.displayID
        let sourceRect = Self.pinnedSourceRect(windowFrame: frame,
                                               norm: selection.normalizedRect,
                                               screen: screen)
        passepartout?.update(hole: Self.pinnedHole(windowFrame: frame,
                                                   norm: selection.normalizedRect))
        retargetPinned(sourceRect: sourceRect, resume: true)
    }

    private func retargetPinned(sourceRect: CGRect, resume: Bool) {
        guard let engine, let selection = currentPinned else { return }
        let windowID = selection.windowID
        let displayID = currentPinnedDisplayID
        Task {
            guard let content = try? await SCShareableContent
                    .excludingDesktopWindows(true, onScreenWindowsOnly: true),
                  let window = content.windows.first(where: { $0.windowID == windowID }),
                  let display = content.displays.first(where: { $0.displayID == displayID })
            else { return }
            engine.retarget(window: window, display: display, sourceRect: sourceRect)
            if resume {
                engine.resume()
            }
        }
    }

    private static func pinnedTarget(for selection: PinnedSelection) async throws -> CaptureTarget {
        let content = try await SCShareableContent
            .excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == selection.windowID })
        else { throw ScrecError.noWindowToRecord }
        guard let screen = screenContaining(selection.frame),
              let display = content.displays.first(where: { $0.displayID == screen.displayID })
        else { throw ScrecError.displayNotFound }
        let sourceRect = pinnedSourceRect(windowFrame: selection.frame,
                                          norm: selection.normalizedRect,
                                          screen: screen)
        return .pinned(window, display, sourceRect)
    }

    // MARK: Geometry helpers

    private static func screenContaining(_ rect: NSRect) -> NSScreen? {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
            ?? NSScreen.screens.max { a, b in
                let ia = a.frame.intersection(rect)
                let ib = b.frame.intersection(rect)
                return ia.width * ia.height < ib.width * ib.height
            }
    }

    /// Sub-area (top-left-normalized within the window) → display-local
    /// top-left sourceRect.
    private static func pinnedSourceRect(windowFrame: NSRect, norm: CGRect,
                                         screen: NSScreen) -> CGRect {
        let windowTopLocal = screen.frame.maxY - windowFrame.maxY
        return CGRect(x: windowFrame.minX - screen.frame.minX + norm.minX * windowFrame.width,
                      y: windowTopLocal + norm.minY * windowFrame.height,
                      width: norm.width * windowFrame.width,
                      height: norm.height * windowFrame.height)
    }

    /// Sub-area → global AppKit rect (for the passe-partout hole).
    private static func pinnedHole(windowFrame: NSRect, norm: CGRect) -> NSRect {
        NSRect(x: windowFrame.minX + norm.minX * windowFrame.width,
               y: windowFrame.minY + (1 - norm.minY - norm.height) * windowFrame.height,
               width: norm.width * windowFrame.width,
               height: norm.height * windowFrame.height)
    }

    private static func display(withID id: CGDirectDisplayID) async throws -> SCDisplay {
        let content = try await SCShareableContent
            .excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == id })
        else { throw ScrecError.displayNotFound }
        return display
    }

    /// Inverse of the selection controller's commit conversion: display-local
    /// top-left rect → global AppKit (bottom-left) rect.
    private static func globalRect(displayID: CGDirectDisplayID,
                                   localTopLeft rect: CGRect) -> NSRect? {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID })
        else { return nil }
        return NSRect(x: screen.frame.minX + rect.minX,
                      y: screen.frame.minY + screen.frame.height - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    private func presentError(_ error: Error) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "screc couldn't record"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    // MARK: - Default-mode persistence

    private struct StoredMode: Codable {
        var kind: String
        var display: UInt32?
        var owner: String?
        var title: String?
        var x: Double?
        var y: Double?
        var width: Double?
        var height: Double?
    }

    private static func mode(for request: CaptureRequest) -> DefaultCaptureMode {
        switch request {
        case .focusedWindow: .window
        case .display(let id): .display(id)
        case .region(let id, let rect): .region(id, rect)
        case .pinnedWindow(let sel): .pinned(ownerName: sel.ownerName,
                                             title: sel.title,
                                             normalizedRect: sel.normalizedRect)
        }
    }

    private func persistDefaultMode() {
        let stored: StoredMode
        switch defaultMode {
        case .window:
            stored = StoredMode(kind: "window")
        case .display(let id):
            stored = StoredMode(kind: "display", display: id)
        case .region(let id, let rect):
            stored = StoredMode(kind: "region", display: id,
                                x: rect.minX, y: rect.minY,
                                width: rect.width, height: rect.height)
        case .pinned(let owner, let title, let rect):
            stored = StoredMode(kind: "pinned", owner: owner, title: title,
                                x: rect.minX, y: rect.minY,
                                width: rect.width, height: rect.height)
        }
        let data = (try? JSONEncoder().encode(stored)) ?? Data()
        UserDefaults.standard.set(data, forKey: DefaultsKey.defaultCaptureMode)
    }

    private static func loadDefaultMode() -> DefaultCaptureMode {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.defaultCaptureMode),
              let stored = try? JSONDecoder().decode(StoredMode.self, from: data)
        else { return .window }
        switch stored.kind {
        case "display":
            return stored.display.map { .display($0) } ?? .window
        case "region":
            if let id = stored.display, let x = stored.x, let y = stored.y,
               let width = stored.width, let height = stored.height {
                return .region(id, CGRect(x: x, y: y, width: width, height: height))
            }
            return .window
        case "pinned":
            if let owner = stored.owner, let title = stored.title,
               let x = stored.x, let y = stored.y,
               let width = stored.width, let height = stored.height {
                return .pinned(ownerName: owner, title: title,
                               normalizedRect: CGRect(x: x, y: y, width: width, height: height))
            }
            return .window
        default:
            return .window
        }
    }
}
