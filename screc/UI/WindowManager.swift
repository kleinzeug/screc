import AppKit
import SwiftUI

/// AppKit-owned windows hosting SwiftUI content. A menu-bar (accessory) app
/// cannot reliably present SwiftUI `Window`/`Settings` scenes, so windows are
/// managed here with the activation-policy dance: flip to .regular to show a
/// window, back to .accessory when the last one closes.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    private let state: AppState
    private let permissions: PermissionManager
    private let store: RecordingStore
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var gifEditorWindow: NSWindow?

    init(state: AppState, permissions: PermissionManager, store: RecordingStore) {
        self.state = state
        self.permissions = permissions
        self.store = store
        super.init()
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let root = OnboardingView(permissions: permissions) { [weak self] in
                UserDefaults.standard.set(true, forKey: DefaultsKey.hasCompletedOnboarding)
                self?.onboardingWindow?.close()
            }
            onboardingWindow = makeWindow(title: "Welcome to sčrec",
                                          content: AnyView(root))
        }
        present(onboardingWindow!)
        permissions.startPolling()
    }

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "sčrec Settings",
                                        content: AnyView(SettingsView(permissions: permissions)))
        }
        present(settingsWindow!)
    }

    func showGIFEditor(url: URL) {
        gifEditorWindow?.close()
        gifEditorWindow = nil
        do {
            let document = try GIFDocument.load(url: url)
            let view = GIFFrameEditorView(
                document: document,
                onSaved: { [weak self] savedURL in
                    self?.store.updateBytes(for: savedURL)
                },
                onClose: { [weak self] in
                    self?.gifEditorWindow?.close()
                })
            let window = makeWindow(title: "Edit GIF — \(url.lastPathComponent)",
                                    content: AnyView(view))
            window.styleMask.insert(.resizable)
            gifEditorWindow = window
            present(window)
        } catch {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Couldn't open GIF"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func makeWindow(title: String, content: AnyView) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        // No sčrec window may ever appear in a recording.
        window.sharingType = .none
        window.center()
        return window
    }

    private func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // True center of the visible screen area — NSWindow.center() would
        // park it in the upper third.
        if !window.isVisible, let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            let frame = window.frame
            window.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2,
                                          y: visible.midY - frame.height / 2))
        }
        window.makeKeyAndOrderFront(nil)
        // Cooperative activation from a background app is flaky on
        // Sonoma/Sequoia; this forces the window frontmost regardless.
        window.orderFrontRegardless()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing == onboardingWindow {
            permissions.stopPolling()
        }
        // Retreat to the menu bar once no screc window remains visible.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let stillVisible = [self.onboardingWindow, self.settingsWindow, self.gifEditorWindow]
                .compactMap { $0 }
                .contains { $0 != closing && $0.isVisible }
            if !stillVisible {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
