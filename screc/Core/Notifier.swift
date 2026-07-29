import Foundation
@preconcurrency import UserNotifications

enum Notifier {
    /// Ask for notification permission at a calm moment (onboarding's "Start
    /// Using screc"), not in the middle of the user's first save.
    static func requestAuthorizationUpfront() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    Log.app.error("notification authorization failed: \(error.localizedDescription)")
                } else if !granted {
                    Log.app.notice("notifications declined — saved-recording banners stay off")
                }
            }
    }

    /// Banner when a recording lands on disk; clicking it opens the file
    /// (handled by the AppDelegate as notification-center delegate). Only
    /// asks for permission if the user skipped onboarding's request.
    static func recordingFinished(url: URL) {
        guard Prefs.notifyOnFinish else { return }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
            as? NSNumber)?.int64Value ?? 0
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { post(url: url, bytes: bytes) }
                }
            case .denied:
                Log.app.notice("recording saved, but notifications are denied in System Settings")
            default:
                post(url: url, bytes: bytes)
            }
        }
    }

    private static func post(url: URL, bytes: Int64) {
        let content = UNMutableNotificationContent()
        content.title = "Recording saved"
        content.body = "\(url.lastPathComponent) · "
            + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        content.userInfo = ["path": url.path]
        UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: UUID().uuidString,
                                       content: content, trigger: nil))
    }
}
