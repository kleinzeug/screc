import Foundation
import UserNotifications

enum Notifier {
    /// Banner when a recording lands on disk; clicking it opens the file
    /// (handled by the AppDelegate as notification-center delegate).
    static func recordingFinished(url: URL) {
        guard Prefs.notifyOnFinish else { return }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
            as? NSNumber)?.int64Value ?? 0
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Recording saved"
            content.body = "\(url.lastPathComponent) · "
                + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            content.userInfo = ["path": url.path]
            center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                             content: content, trigger: nil))
        }
    }
}
