import Foundation

enum DefaultsKey {
    static let hasCompletedOnboarding = "hasCompletedOnboarding"
    static let hasRequestedScreenPermission = "hasRequestedScreenPermission"
    static let outputPreset = "outputPreset"
    static let showsCursor = "showsCursor"
    static let captureSystemAudio = "captureSystemAudio"
    static let recentRecordings = "recentRecordings"
    static let defaultCaptureMode = "defaultCaptureMode"
    static let discardShortRecordings = "discardShortRecordings"
    static let memoryRegion = "memoryRegion"
    static let memoryPinned = "memoryPinned"
    static let memoryDisplay = "memoryDisplay"
    static let currentRecordingConfig = "currentRecordingConfig"
    static let customPresets = "customPresets"
    static let storageChoice = "storageChoice"
    static let customStoragePath = "customStoragePath"
    static let fileNamePattern = "fileNamePattern"
    static let notifyOnFinish = "notifyOnFinish"
    static let countdownEnabled = "countdownEnabled"
    static let micEnabled = "micEnabled"
    static let micDeviceID = "micDeviceID"
    static let micGain = "micGain"
    static let debugMode = "debugMode"
}

/// Read-side helpers with defaults that match the SwiftUI `@AppStorage`
/// declarations in the settings UI.
enum Prefs {
    static var showsCursor: Bool {
        (UserDefaults.standard.object(forKey: DefaultsKey.showsCursor) as? Bool) ?? true
    }
    static var captureSystemAudio: Bool {
        (UserDefaults.standard.object(forKey: DefaultsKey.captureSystemAudio) as? Bool) ?? true
    }
    static var discardShortRecordings: Bool {
        (UserDefaults.standard.object(forKey: DefaultsKey.discardShortRecordings) as? Bool) ?? true
    }
    /// "tmp" | "movies" | "custom"
    static var storageChoice: String {
        UserDefaults.standard.string(forKey: DefaultsKey.storageChoice) ?? "tmp"
    }
    static var customStoragePath: String {
        UserDefaults.standard.string(forKey: DefaultsKey.customStoragePath) ?? ""
    }
    static var fileNamePattern: String {
        UserDefaults.standard.string(forKey: DefaultsKey.fileNamePattern) ?? "screc-{date}-{time}"
    }
    static var notifyOnFinish: Bool {
        (UserDefaults.standard.object(forKey: DefaultsKey.notifyOnFinish) as? Bool) ?? true
    }
    /// 3-2-1 overlay before capture starts. Off by default.
    static var countdownEnabled: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.countdownEnabled)
    }
    /// Microphone capture. Off by default; enabling it in Settings triggers
    /// the permission request.
    static var micEnabled: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.micEnabled)
    }
    /// Selected input device UID; empty string = system default.
    static var micDeviceID: String {
        UserDefaults.standard.string(forKey: DefaultsKey.micDeviceID) ?? ""
    }
    /// Microphone level in the final mix, 0…1.
    static var micGain: Double {
        (UserDefaults.standard.object(forKey: DefaultsKey.micGain) as? Double) ?? 1.0
    }
    /// Development escape hatch: pretend the screen-recording permission was
    /// granted and record black frames, so the UI can be exercised without
    /// re-granting access after every rebuild. Never enabled by default.
    static var debugMode: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.debugMode)
    }
}
