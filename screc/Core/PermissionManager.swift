import AppKit
import CoreGraphics
import Combine

/// Screen-recording permission (TCC). There is no entitlement for screen
/// capture — only the user-facing privacy grant. Two macOS quirks shape this
/// type:
///  - `CGRequestScreenCaptureAccess()` shows the system prompt only once,
///    ever, while the state is undetermined; afterwards only the user can
///    flip the toggle in System Settings.
///  - A grant does NOT take effect in the running process; a relaunch is
///    required (DTS-confirmed behavior on macOS 14/15/26).
@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var granted = false {
        didSet { if oldValue != granted { onChange?() } }
    }
    @Published private(set) var hasRequested =
        UserDefaults.standard.bool(forKey: DefaultsKey.hasRequestedScreenPermission)

    /// AppKit-side observer hook (the status item).
    var onChange: (() -> Void)?

    private var pollTimer: Timer?

    /// True in debug mode as well, so every gated code path opens up.
    @Published private(set) var debugMode = Prefs.debugMode {
        didSet { onChange?() }
    }

    func refresh() {
        debugMode = Prefs.debugMode
        granted = debugMode || CGPreflightScreenCaptureAccess()
    }

    func setDebugMode(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.debugMode)
        refresh()
    }

    func requestAccess() {
        hasRequested = true
        UserDefaults.standard.set(true, forKey: DefaultsKey.hasRequestedScreenPermission)
        CGRequestScreenCaptureAccess()
        refresh()
    }

    func openSystemSettings() {
        // Verified working on macOS 15.7: opens Privacy & Security scrolled to
        // Screen & System Audio Recording.
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// Relaunch to pick up a grant: schedule a delayed `open -n` of our own
    /// bundle from a detached shell, then terminate this instance. The delay
    /// avoids two live instances fighting over the status bar.
    func relaunch() {
        let path = Bundle.main.bundlePath.replacingOccurrences(of: "\"", with: "\\\"")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open -n \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// Poll while the onboarding window is visible. Note the preflight verdict
    /// usually stays stale until relaunch — the onboarding copy explains that;
    /// polling just catches the cases where it does update.
    func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
