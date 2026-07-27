import AppKit
import KeyboardShortcuts
@preconcurrency import UserNotifications

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording")
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

        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
            guard let self else { return }
            switch self.state.phase {
            case .recording:
                self.state.stopRecording()
            case .idle:
                if self.permissions.granted {
                    self.state.recordDefault()
                }
            case .selecting, .finishing:
                break
            }
        }

        let onboarded = UserDefaults.standard.bool(forKey: DefaultsKey.hasCompletedOnboarding)
        if !onboarded || !permissions.granted {
            windowManager.showOnboarding()
        }
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
