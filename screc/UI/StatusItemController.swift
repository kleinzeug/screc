import AppKit

/// The menu-bar shell. A raw NSStatusItem (SwiftUI's MenuBarExtra cannot
/// distinguish click buttons nor render 9 pt stats text):
///  - LEFT-click  → options menu
///  - RIGHT-click → primary action (start with the remembered default mode /
///    stop / cancel selection)
///  - while recording the item expands with compact fixed-width live stats
///    placed LEFT of the icon (`imageTrailing`): status items grow leftward,
///    so the icon — the click target — never moves between start and stop.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let state: AppState
    private let permissions: PermissionManager
    private let windowManager: WindowManager
    private let store: RecordingStore
    private let statusItem: NSStatusItem

    init(state: AppState, permissions: PermissionManager,
         windowManager: WindowManager, store: RecordingStore) {
        self.state = state
        self.permissions = permissions
        self.windowManager = windowManager
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        state.onChange = { [weak self] in self?.updateAppearance() }
        permissions.onChange = { [weak self] in self?.updateAppearance() }
        updateAppearance()
    }

    // MARK: - Appearance

    private func updateAppearance() {
        guard let button = statusItem.button else { return }
        switch state.phase {
        case .recording:
            button.image = Icons.recordingStop
            button.imagePosition = .imageTrailing
            button.attributedTitle = Self.statsTitle(state.stats)
            button.toolTip = "sčrec — click to stop recording"
        case .finishing:
            button.image = Icons.saving
            button.imagePosition = .imageTrailing
            button.attributedTitle = Self.smallTitle(state.finishingLabel + " ")
            button.toolTip = "sčrec — finalizing recording"
        case .selecting:
            button.image = Icons.selecting
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = "sčrec — make a selection (Esc cancels)"
        case .idle:
            button.image = permissions.granted ? Icons.readyRedDot : Icons.recordNoPermission
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = permissions.granted
                ? "sčrec — right-click to record \(modeDescription), left-click for the menu"
                : "sčrec — screen-recording permission needed"
        }
    }

    private var modeDescription: String {
        switch state.defaultMode {
        case .window: "the focused window"
        case .display: "the full screen"
        case .region: "the last region"
        case .pinned: "the pinned window"
        }
    }

    /// Fixed-width stats: every numeric field is padded with figure spaces
    /// (digit-width in the monospaced-digit font), so the item's width never
    /// bounces while recording.
    private static func statsTitle(_ stats: RecordingStats) -> NSAttributedString {
        let megabytes = Double(stats.bytesWritten) / 1_048_576
        var parts = [
            pad(format(duration: stats.duration), to: 5),
            pad(String(format: "%.1f", megabytes), to: 5) + " MB",
            pad(stats.isPaused ? "paused" : pad("\(Int(stats.framesPerSecond))", to: 2) + "fps",
                to: 6),
        ]
        if stats.framesDropped > 0 {
            parts.append(pad("\(stats.framesDropped)", to: 3) + " drop")
        }
        return smallTitle(parts.joined(separator: " · ") + " ")
    }

    private static func pad(_ text: String, to width: Int) -> String {
        text.count >= width
            ? text
            : String(repeating: "\u{2007}", count: width - text.count) + text
    }

    private static func smallTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .baselineOffset: 0.5,
        ])
    }

    private static func format(duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    private enum Icons {
        /// Operational: ring + red center dot. Recording: ring + monochrome
        /// stop square inside the same ring, so start/stop reads as one
        /// control. Custom-drawn (a template image can't mix an adaptive ring
        /// with a fixed red dot); dynamic colors resolve at draw time, so
        /// light/dark menu bars work.
        static let readyRedDot = ringIcon(center: .redDot)
        static let recordingStop = ringIcon(center: .stopSquare)

        /// Permission missing: hollow, monochrome — "not set up yet".
        static let recordNoPermission: NSImage = {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            let image = NSImage(systemSymbolName: "record.circle",
                                accessibilityDescription: "Record (permission needed)")!
                .withSymbolConfiguration(config)!
            image.isTemplate = true
            return image
        }()

        static let saving: NSImage = {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            let image = NSImage(systemSymbolName: "hourglass",
                                accessibilityDescription: "Saving")!
                .withSymbolConfiguration(config)!
            image.isTemplate = true
            return image
        }()

        static let selecting: NSImage = {
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            let image = NSImage(systemSymbolName: "viewfinder",
                                accessibilityDescription: "Selecting")!
                .withSymbolConfiguration(config)!
            image.isTemplate = true
            return image
        }()

        private enum CenterGlyph { case redDot, stopSquare }

        private static func ringIcon(center glyph: CenterGlyph) -> NSImage {
            let image = NSImage(size: NSSize(width: 18, height: 18),
                                flipped: false) { rect in
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.75, dy: 1.75))
                ring.lineWidth = 1.5
                NSColor.labelColor.setStroke()
                ring.stroke()
                switch glyph {
                case .redDot:
                    NSColor.systemRed.setFill()
                    NSBezierPath(ovalIn: rect.insetBy(dx: 5.25, dy: 5.25)).fill()
                case .stopSquare:
                    NSColor.labelColor.setFill()
                    NSBezierPath(roundedRect: rect.insetBy(dx: 5.75, dy: 5.75),
                                 xRadius: 1.5, yRadius: 1.5).fill()
                }
                return true
            }
            image.isTemplate = false
            return image
        }
    }

    // MARK: - Click routing (left = menu, right = record; ANY click stops)

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if state.phase == .recording {
            state.stopRecording()
            return
        }
        if NSApp.currentEvent?.type == .rightMouseUp {
            primaryAction()
        } else {
            showMenu()
        }
    }

    private func primaryAction() {
        switch state.phase {
        case .recording:
            state.stopRecording()
        case .idle:
            if permissions.granted {
                state.recordDefault()
            } else {
                windowManager.showOnboarding()
            }
        case .selecting:
            state.cancelSelection()
        case .finishing:
            break
        }
    }

    // MARK: - Menu

    private func showMenu() {
        let menu = buildMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        switch state.phase {
        case .recording:
            menu.addItem(item("Stop Recording", action: #selector(stopFromMenu)))
        case .finishing:
            let saving = item(state.finishingLabel.capitalized, action: nil)
            saving.isEnabled = false
            menu.addItem(saving)
        case .selecting:
            menu.addItem(item("Cancel Selection", action: #selector(cancelSelection)))
        case .idle:
            menu.addItem(NSMenuItem.sectionHeader(title: "Start Recording"))
            // The checkmark marks the right-click default (last-used mode).
            let front = item("Focused Window", action: #selector(recordFocused))
            front.isEnabled = permissions.granted
            front.state = state.defaultMode == .window ? .on : .off
            menu.addItem(front)
            let pinned = item("Selected Window", action: #selector(recordPinned))
            pinned.isEnabled = permissions.granted
            if case .pinned = state.defaultMode { pinned.state = .on }
            menu.addItem(pinned)
            let region = item("Screen Region", action: #selector(recordRegion))
            region.isEnabled = permissions.granted
            if case .region = state.defaultMode { region.state = .on }
            menu.addItem(region)
            menu.addItem(fullScreenItem())
        }

        store.validate()
        if !store.recordings.isEmpty {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: "Recent Recordings"))
            for recording in store.recordings {
                let size = ByteCountFormatter.string(fromByteCount: recording.bytes,
                                                     countStyle: .file)
                let entry = item("\(recording.name)  ·  \(size)",
                                 action: #selector(openRecording(_:)))
                entry.representedObject = recording.url
                entry.keyEquivalentModifierMask = []
                menu.addItem(entry)
                // ⌥ swaps the entry for its secondary action.
                let isGIF = recording.url.pathExtension.lowercased() == "gif"
                let alternate = isGIF
                    ? item("Edit Frames  ·  \(recording.name)",
                           action: #selector(editRecording(_:)))
                    : item("Convert to GIF  ·  \(recording.name)",
                           action: #selector(convertRecording(_:)))
                alternate.representedObject = recording.url
                alternate.isAlternate = true
                alternate.keyEquivalentModifierMask = [.option]
                if !isGIF { alternate.isEnabled = state.phase == .idle }
                menu.addItem(alternate)
            }
            let freed = ByteCountFormatter.string(fromByteCount: store.totalBytes,
                                                  countStyle: .file)
            menu.addItem(item("Clear All (frees \(freed))", action: #selector(clearAll)))
        }

        menu.addItem(.separator())
        if !permissions.granted {
            menu.addItem(item("Grant Screen Recording Access…",
                              action: #selector(openOnboarding)))
        }
        menu.addItem(item("Settings…", action: #selector(openSettings), key: ","))
        menu.addItem(item("About sčrec…", action: #selector(openAbout)))
        menu.addItem(.separator())
        menu.addItem(item("Quit sčrec", action: #selector(quit), key: "q"))
        return menu
    }

    private func fullScreenItem() -> NSMenuItem {
        let defaultDisplayID: CGDirectDisplayID? = {
            if case .display(let id) = state.defaultMode { return id }
            return nil
        }()
        let screens = NSScreen.screens
        if screens.count <= 1 {
            let single = item("Full Screen", action: #selector(recordDisplay(_:)))
            single.tag = Int(screens.first?.displayID ?? CGMainDisplayID())
            single.isEnabled = permissions.granted
            single.state = defaultDisplayID != nil ? .on : .off
            return single
        }
        let parent = item("Full Screen", action: nil)
        parent.isEnabled = permissions.granted
        parent.state = defaultDisplayID != nil ? .on : .off
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for screen in screens {
            let entry = item(screen.localizedName, action: #selector(recordDisplay(_:)))
            entry.tag = Int(screen.displayID)
            entry.isEnabled = permissions.granted
            entry.state = defaultDisplayID == screen.displayID ? .on : .off
            submenu.addItem(entry)
        }
        parent.submenu = submenu
        return parent
    }

    private func item(_ title: String, action: Selector?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func recordFocused() { state.record(.focusedWindow) }

    @objc private func recordPinned() { state.selectPinnedWindow() }

    @objc private func recordDisplay(_ sender: NSMenuItem) {
        state.record(.display(CGDirectDisplayID(sender.tag)))
    }

    @objc private func recordRegion() { state.selectRegion() }

    @objc private func cancelSelection() { state.cancelSelection() }

    @objc private func stopFromMenu() { state.stopRecording() }

    @objc private func openRecording(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        RecordingOpener.open(url)
    }

    @objc private func convertRecording(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        state.convertToGIF(url)
    }

    @objc private func editRecording(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        windowManager.showGIFEditor(url: url)
    }

    @objc private func clearAll() { store.clearAll() }
    @objc private func openOnboarding() { windowManager.showOnboarding() }
    @objc private func openSettings() { windowManager.showSettings() }
    @objc private func openAbout() { windowManager.showOnboarding() }
    @objc private func quit() { NSApp.terminate(nil) }
}
