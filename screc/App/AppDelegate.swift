import AppKit
import KeyboardShortcuts
@preconcurrency import UserNotifications

/// One shortcut per capture mode. Each ships with a default; rebinding in
/// Settings overrides it, and clearing the override restores the default.
extension KeyboardShortcuts.Name {
    static let recordSelectedWindow = Self("recordSelectedWindow",
                                           default: .init(.eight, modifiers: [.command, .shift]))
    static let recordFocusedWindow = Self("recordFocusedWindow",
                                          default: .init(.eight, modifiers: [.command, .option, .shift]))
    static let recordFullScreen = Self("recordFullScreen",
                                       default: .init(.nine, modifiers: [.command, .shift]))
    static let recordRegion = Self("recordRegion",
                                   default: .init(.nine, modifiers: [.command, .option, .shift]))
    /// Completes the row: 8 starts window modes, 9 area modes, 0 stops.
    static let stopRecording = Self("stopRecording",
                                    default: .init(.zero, modifiers: [.command, .shift]))
    /// The ⌥ variant of stop, matching the ⌥-click on the status item.
    static let pauseRecording = Self("pauseRecording",
                                     default: .init(.zero, modifiers: [.command, .option, .shift]))

    static let allRecordingShortcuts: [(name: Self, label: String)] = [
        (.recordFocusedWindow, "Focused Window"),
        (.recordSelectedWindow, "Selected Window"),
        (.recordRegion, "Screen Region"),
        (.recordFullScreen, "Full Screen"),
        (.stopRecording, "Stop recording"),
        (.pauseRecording, "Pause / Resume"),
    ]
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let permissions = PermissionManager()
    private var store: RecordingStore!
    private var state: AppState!
    private var windowManager: WindowManager!
    private var statusItemController: StatusItemController!
    private var regionController: RegionSelectionController!
    private var windowPicker: WindowPickController!
    private var screenPicker: ScreenPickController!
    private var passepartout: PassepartoutController!
    private var windowTracker: FocusedWindowTracker!
    private var pinnedTracker: PinnedWindowTracker!
    private var countdownController: CountdownController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        permissions.refresh()
        store = RecordingStore()
        state = AppState(store: store)
        regionController = RegionSelectionController()
        state.regionSelector = regionController
        windowPicker = WindowPickController()
        state.windowPicker = windowPicker
        screenPicker = ScreenPickController()
        state.screenPicker = screenPicker
        passepartout = PassepartoutController()
        state.passepartout = passepartout
        windowTracker = FocusedWindowTracker()
        state.windowTracker = windowTracker
        pinnedTracker = PinnedWindowTracker()
        state.pinnedTracker = pinnedTracker
        countdownController = CountdownController()
        state.countdown = countdownController
        windowManager = WindowManager(state: state, permissions: permissions, store: store)
        statusItemController = StatusItemController(
            state: state,
            permissions: permissions,
            windowManager: windowManager,
            store: store
        )

        UNUserNotificationCenter.current().delegate = self
        registerShortcuts()

        let onboarded = UserDefaults.standard.bool(forKey: DefaultsKey.hasCompletedOnboarding)
        if !onboarded || !permissions.granted {
            windowManager.showOnboarding()
        }
    }

    /// While a recording runs, any of the four shortcuts stops it — the same
    /// toggle behavior as clicking the status item.
    private func registerShortcuts() {
        func bind(_ name: KeyboardShortcuts.Name, _ action: @escaping (AppState) -> Void) {
            KeyboardShortcuts.onKeyUp(for: name) { [weak self] in
                guard let self else { return }
                guard self.permissions.granted else {
                    // A silent no-op reads as "the hotkey is broken" — show
                    // what is actually missing instead.
                    self.windowManager.showOnboarding()
                    return
                }
                switch self.state.phase {
                case .recording: self.state.stopRecording()
                case .countdown: self.state.cancelCountdown() // toggle semantics
                case .idle: action(self.state)
                case .selecting, .finishing: break
                }
            }
        }
        bind(.recordFocusedWindow) { $0.record(.focusedWindow) }
        bind(.recordSelectedWindow) { $0.recordSelectedWindowRemembered() }
        bind(.recordRegion) { $0.recordRegionRemembered() }
        bind(.recordFullScreen) { $0.recordFullScreenRemembered() }

        KeyboardShortcuts.onKeyUp(for: .pauseRecording) { [weak self] in
            self?.state.togglePause()
        }

        // Stop is available regardless of how the recording was started, and
        // doubles as an escape from a picker that is still open.
        KeyboardShortcuts.onKeyUp(for: .stopRecording) { [weak self] in
            guard let self else { return }
            switch self.state.phase {
            case .recording: self.state.stopRecording()
            case .selecting: self.state.cancelSelection()
            case .countdown: self.state.cancelCountdown()
            case .idle, .finishing: break
            }
        }
    }

    /// A quit while recording (menu, ⌘Q, logout, shutdown) must never tear
    /// down a live AVAssetWriter — an unfinalized MP4 has no moov atom and is
    /// unreadable. Stop, wait for the file to land, then let go.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if state.phase == .countdown {
            state.cancelCountdown()
        }
        if state.phase == .recording {
            state.stopRecording()
        }
        guard state.phase == .finishing else { return .terminateNow }
        terminationReplyPending = true
        state.onReturnToIdle = { [weak self] in self?.replyToPendingTermination() }
        // Safety net: a hung finalization must not make the app unquittable.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            self?.replyToPendingTermination()
        }
        return .terminateLater
    }

    private var terminationReplyPending = false

    private func replyToPendingTermination() {
        guard terminationReplyPending else { return }
        terminationReplyPending = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    // Clicking the "Recording saved" banner opens the file.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let path = response.notification.request.content.userInfo["path"] as? String
        Task { @MainActor in
            if let path {
                RecordingOpener.open(URL(fileURLWithPath: path))
            }
        }
        completionHandler()
    }

    // Show banners even while screc is the active app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
