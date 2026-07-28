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

    static let allRecordingShortcuts: [(name: Self, label: String)] = [
        (.recordFocusedWindow, "Focused Window"),
        (.recordSelectedWindow, "Selected Window"),
        (.recordRegion, "Screen Region"),
        (.recordFullScreen, "Full Screen"),
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
                guard let self, self.permissions.granted else { return }
                if self.state.phase == .recording {
                    self.state.stopRecording()
                } else if self.state.phase == .idle {
                    action(self.state)
                }
            }
        }
        bind(.recordFocusedWindow) { $0.record(.focusedWindow) }
        bind(.recordSelectedWindow) { $0.recordSelectedWindowRemembered() }
        bind(.recordRegion) { $0.recordRegionRemembered() }
        bind(.recordFullScreen) { $0.recordFullScreenRemembered() }
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
