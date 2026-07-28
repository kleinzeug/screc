import AppKit
import KeyboardShortcuts

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
            button.toolTip = "screc — click to stop recording"
        case .finishing:
            button.image = Icons.saving
            button.imagePosition = .imageTrailing
            button.attributedTitle = Self.smallTitle(state.finishingLabel + " ")
            button.toolTip = "screc — finalizing recording"
        case .selecting:
            button.image = Icons.selecting
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = "screc — make a selection (Esc cancels)"
        case .idle:
            button.image = permissions.granted ? Icons.readyRedDot : Icons.recordNoPermission
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = permissions.granted
                ? "screc — right-click to record \(modeDescription), left-click for the menu"
                : "screc — screen-recording permission needed"
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

    @MainActor
    private enum Icons {
        /// Idle: the classic "● REC" badge (red dot only when operational;
        /// hollow dot while the screen-recording permission is missing).
        /// Recording: ring + monochrome stop square. Custom-drawn (a template
        /// image can't mix an adaptive label color with a fixed red dot);
        /// dynamic colors resolve at draw time, so light/dark menu bars work.
        static let readyRedDot = recBadge(hollowDot: false)
        static let recordNoPermission = recBadge(hollowDot: true)
        static let recordingStop = ringIcon(center: .stopSquare)

        private static func recBadge(hollowDot: Bool) -> NSImage {
            let font = NSFont.systemFont(ofSize: 11, weight: .heavy)
            let text = NSAttributedString(string: "REC", attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .kern: 0.6,
            ])
            let textSize = text.size()
            let dot: CGFloat = 8
            let gap: CGFloat = 4
            let size = NSSize(width: dot + gap + textSize.width.rounded(.up) + 2,
                              height: 18)
            let image = NSImage(size: size, flipped: false) { rect in
                let dotRect = NSRect(x: 1, y: (rect.height - dot) / 2,
                                     width: dot, height: dot)
                if hollowDot {
                    NSColor.labelColor.setStroke()
                    let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.75, dy: 0.75))
                    ring.lineWidth = 1.5
                    ring.stroke()
                } else {
                    NSColor.systemRed.setFill()
                    NSBezierPath(ovalIn: dotRect).fill()
                }
                text.draw(at: NSPoint(x: 1 + dot + gap,
                                      y: (rect.height - textSize.height) / 2))
                return true
            }
            image.isTemplate = false
            return image
        }

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

        private enum CenterGlyph { case stopSquare }

        private static func ringIcon(center glyph: CenterGlyph) -> NSImage {
            let image = NSImage(size: NSSize(width: 18, height: 18),
                                flipped: false) { rect in
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.75, dy: 1.75))
                ring.lineWidth = 1.5
                NSColor.labelColor.setStroke()
                ring.stroke()
                switch glyph {
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
            // Each mode gets a plain entry (ask me) and an ⌥ alternate that
            // reuses what the mode last recorded. The checkmark marks the
            // mode the primary click and the status item repeat.
            addModeItems(to: menu)
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
        menu.addItem(item("About screc…", action: #selector(openAbout)))
        menu.addItem(.separator())
        menu.addItem(item("Quit screc", action: #selector(quit), key: "q"))
        return menu
    }

    /// The four modes. A title that names its remembered configuration
    /// records straight away; a title ending in "…" opens a picker first
    /// (the usual macOS convention). Holding ⌥ turns any configured entry
    /// back into its picker, which is how a configuration gets replaced.
    private func addModeItems(to menu: NSMenu) {
        func add(configured: String?,
                 pickerTitle: String,
                 instantAction: Selector,
                 pickerAction: Selector,
                 shortcut: KeyboardShortcuts.Name,
                 isDefault: Bool) {
            let main = item(configured ?? pickerTitle,
                            action: configured != nil ? instantAction : pickerAction)
            main.isEnabled = permissions.granted
            main.state = isDefault ? .on : .off
            main.setShortcut(for: shortcut)
            menu.addItem(main)

            // ⌥: reconfigure. Only meaningful once something is remembered.
            guard configured != nil else { return }
            let alt = item(pickerTitle, action: pickerAction)
            alt.isEnabled = permissions.granted
            alt.state = isDefault ? .on : .off
            alt.isAlternate = true
            alt.keyEquivalentModifierMask = [.option]
            menu.addItem(alt)
        }

        var isWindowDefault = false, isPinnedDefault = false
        var isRegionDefault = false, isDisplayDefault = false
        switch state.defaultMode {
        case .window: isWindowDefault = true
        case .pinned: isPinnedDefault = true
        case .region: isRegionDefault = true
        case .display: isDisplayDefault = true
        }

        // Focused window is inherently "whatever is focused now" — nothing
        // to remember, so no picker and no suffix.
        let focused = item("Focused Window", action: #selector(recordFocused))
        focused.isEnabled = permissions.granted
        focused.state = isWindowDefault ? .on : .off
        focused.setShortcut(for: .recordFocusedWindow)
        menu.addItem(focused)

        add(configured: ModeMemory.pinned.map { "Selected Window — \(Self.windowLabel(for: $0))" },
            pickerTitle: "Selected Window…",
            instantAction: #selector(recordPinnedRemembered),
            pickerAction: #selector(recordPinned),
            shortcut: .recordSelectedWindow,
            isDefault: isPinnedDefault)

        add(configured: ModeMemory.usableRegion().map { "Screen Region — \(Self.regionLabel(for: $0.1))" },
            pickerTitle: "Screen Region…",
            instantAction: #selector(recordRegionRemembered),
            pickerAction: #selector(recordRegion),
            shortcut: .recordRegion,
            isDefault: isRegionDefault)

        add(configured: ModeMemory.usableDisplay().map { "Full Screen — \(Self.screenLabel(for: $0))" },
            pickerTitle: "Full Screen…",
            instantAction: #selector(recordFullScreenRemembered),
            pickerAction: #selector(pickScreen),
            shortcut: .recordFullScreen,
            isDefault: isDisplayDefault)
    }

    /// Window titles can be arbitrarily long; keep the menu a sane width.
    private static func windowLabel(for pinned: ModeMemory.Pinned) -> String {
        let raw = pinned.title.trimmingCharacters(in: .whitespaces)
        let text = raw.isEmpty ? pinned.ownerName : raw
        let limit = 32
        guard text.count > limit else { return text }
        return text.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Display-local origin and size of the remembered region.
    private static func regionLabel(for rect: CGRect) -> String {
        "[\(Int(rect.minX)),\(Int(rect.minY))]×[\(Int(rect.width)),\(Int(rect.height))]"
    }

    private static func screenLabel(for displayID: CGDirectDisplayID) -> String {
        NSScreen.screens.first { $0.displayID == displayID }?.localizedName ?? "Display"
    }

    private func item(_ title: String, action: Selector?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func recordFocused() { state.record(.focusedWindow) }

    @objc private func recordPinned() { state.selectPinnedWindow() }

    @objc private func recordRegion() { state.selectRegion() }

    @objc private func pickScreen() { state.pickScreen() }
    @objc private func recordRegionRemembered() { state.recordRegionRemembered() }
    @objc private func recordPinnedRemembered() { state.recordSelectedWindowRemembered() }
    @objc private func recordFullScreenRemembered() { state.recordFullScreenRemembered() }

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
