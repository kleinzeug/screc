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
    private var modeEntries: [ModeEntry] = []
    private var altTimer: Timer?
    private var altActive = false
    private var hasAppliedAlt = false

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
            button.toolTip = "screc — click to stop, ⌥-click to pause/resume"
            button.setAccessibilityLabel(state.stats.isPaused
                ? "screc, recording paused, click to stop, option-click to resume"
                : "screc, recording, click to stop, option-click to pause")
        case .finishing:
            button.image = Icons.saving
            button.imagePosition = .imageTrailing
            button.attributedTitle = Self.smallTitle(state.finishingLabel + " ")
            button.toolTip = "screc — finalizing recording"
            button.setAccessibilityLabel("screc, \(state.finishingLabel)")
        case .selecting:
            button.image = Icons.selecting
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = "screc — make a selection (Esc cancels)"
            button.setAccessibilityLabel("screc, choosing what to record")
        case .countdown:
            button.image = Icons.selecting
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = "screc — recording starts shortly, click to cancel"
            button.setAccessibilityLabel("screc, countdown running, click to cancel")
        case .idle:
            button.image = permissions.granted ? Icons.readyRedDot : Icons.recordNoPermission
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = permissions.granted
                ? "screc — right-click to record \(modeDescription), left-click for the menu"
                : "screc — screen-recording permission needed"
            button.setAccessibilityLabel(permissions.granted
                ? "screc, ready to record"
                : "screc, screen-recording permission needed")
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

        /// Trash glyph for the ⌥ Delete row. An SF Symbol as a TEMPLATE image
        /// rather than the Unicode wastebasket (U+1F5D1): that codepoint
        /// renders as a fixed multicolor emoji, while a template image is a
        /// flat silhouette AppKit tints with the menu's label color — so it
        /// follows light and dark mode automatically.
        static let trash: NSImage? = {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            guard let image = NSImage(systemSymbolName: "trash",
                                      accessibilityDescription: "Delete")?
                .withSymbolConfiguration(config)
            else { return nil }
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
            // ⌥-click pauses/resumes instead of stopping.
            if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
                state.togglePause()
            } else {
                state.stopRecording()
            }
            return
        }
        if state.phase == .countdown {
            state.cancelCountdown()
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
        case .countdown:
            state.cancelCountdown()
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

    func menuWillOpen(_ menu: NSMenu) {
        startAltTracking()
    }

    func menuDidClose(_ menu: NSMenu) {
        stopAltTracking()
        modeEntries.removeAll()
        statusItem.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        switch state.phase {
        case .recording:
            let stop = item("Stop Recording", action: #selector(stopFromMenu))
            stop.setShortcut(for: .stopRecording)
            menu.addItem(stop)
            // ⌥ swaps it for pause/resume — same in-place mechanism as the
            // mode entries (isAlternate would need a shared key equivalent).
            modeEntries.removeAll()
            modeEntries.append(ModeEntry(
                item: stop,
                plainTitle: "Stop Recording",
                configuredTitle: state.isUserPaused ? "Resume Recording" : "Pause Recording",
                pickerAction: #selector(stopFromMenu),
                instantAction: #selector(togglePauseFromMenu)))
            applyAlt(NSEvent.modifierFlags.contains(.option))
        case .finishing:
            let saving = item(state.finishingLabel.capitalized, action: nil)
            saving.isEnabled = false
            menu.addItem(saving)
        case .selecting:
            menu.addItem(item("Cancel Selection", action: #selector(cancelSelection)))
        case .countdown:
            menu.addItem(item("Cancel Countdown", action: #selector(cancelCountdown)))
        case .idle:
            menu.addItem(NSMenuItem.sectionHeader(title: "Start Recording"))
            // Each mode gets a plain entry (ask me) and an ⌥ alternate that
            // reuses what the mode last recorded. The checkmark marks the
            // mode the primary click and the status item repeat.
            addModeItems(to: menu)
        }

        store.validate()
        let older = store.olderRecordings()
        if !store.recordings.isEmpty || !older.isEmpty {
            menu.addItem(.separator())
            if !store.recordings.isEmpty {
                menu.addItem(NSMenuItem.sectionHeader(title: "Recent Recordings"))
                for recording in store.recordings {
                    addRecordingRows(url: recording.url, bytes: recording.bytes, to: menu)
                }
            }
            // Files that scrolled out of the recents list (or predate this
            // run) stay reachable instead of silently accumulating on disk.
            if !older.isEmpty {
                let parent = item("Older Recordings (\(older.count))", action: nil)
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                for file in older.prefix(Self.olderMenuLimit) {
                    addRecordingRows(url: file.url, bytes: file.bytes, to: submenu)
                }
                if older.count > Self.olderMenuLimit {
                    let more = item("… and \(older.count - Self.olderMenuLimit) more",
                                    action: nil)
                    more.isEnabled = false
                    submenu.addItem(more)
                }
                submenu.addItem(.separator())
                let olderBytes = older.reduce(0) { $0 + $1.bytes }
                let olderSize = ByteCountFormatter.string(fromByteCount: olderBytes,
                                                          countStyle: .file)
                // Clears only the overhang — the recents above stay.
                let clearOlder = Prefs.storageChoice == "tmp"
                    ? item("Clear Older Recordings (frees \(olderSize))",
                           action: #selector(clearOlderRecordings))
                    : item("Clear Older Recordings (\(olderSize))…",
                           action: #selector(clearOlderRecordings))
                submenu.addItem(clearOlder)
                submenu.addItem(item("Open Folder in Finder",
                                     action: #selector(openStorageFolder)))
                parent.submenu = submenu
                menu.addItem(parent)
            }
            let totalBytes = store.totalBytes + older.reduce(0) { $0 + $1.bytes }
            let size = ByteCountFormatter.string(fromByteCount: totalBytes,
                                                 countStyle: .file)
            // /tmp clears immediately (throwaway by design); permanent
            // locations confirm and go through the Trash — hence the ellipsis.
            let clear = Prefs.storageChoice == "tmp"
                ? item("Clear All (frees \(size))", action: #selector(clearAll))
                : item("Clear All (\(size))…", action: #selector(clearAll))
            menu.addItem(clear)
        }

        menu.addItem(.separator())
        if !permissions.granted {
            menu.addItem(item("Grant Screen Recording Access…",
                              action: #selector(openOnboarding)))
        }
        menu.addItem(item("Settings…", action: #selector(openSettings), key: ","))
        menu.addItem(item("About screc…", action: #selector(openAbout)))
        menu.addItem(.separator())
        // Quitting mid-recording is safe (the app delegate finalizes the file
        // first) — the label just says so.
        menu.addItem(item(state.phase == .recording ? "Stop & Quit screc" : "Quit screc",
                          action: #selector(quit), key: "q"))
        return menu
    }

    /// Keep the submenu skimmable; overflow is a disabled "… and N more" row
    /// plus the Finder escape hatch.
    private static let olderMenuLimit = 25

    /// The four menu rows every listed recording gets: open, plus alternates
    /// for ⌥ (Delete), ⌘ (Reveal in Finder) and ⇧ (Convert to GIF / Edit
    /// Frames). The rows share an empty key equivalent, so AppKit pairs the
    /// alternates by modifier mask.
    private func addRecordingRows(url: URL, bytes: Int64, to menu: NSMenu) {
        let name = url.lastPathComponent
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let entry = item("\(name)  ·  \(size)", action: #selector(openRecording(_:)))
        entry.representedObject = url
        entry.keyEquivalentModifierMask = []
        menu.addItem(entry)

        // ⌥ deletes. The trash glyph marks it out as the destructive row at a
        // glance; permanent storage locations move the file to the Trash
        // rather than erasing it (RecordingStore.delete).
        let delete = item("Delete  ·  \(name)", action: #selector(deleteRecording(_:)))
        delete.representedObject = url
        delete.isAlternate = true
        delete.keyEquivalentModifierMask = [.option]
        delete.image = Icons.trash
        menu.addItem(delete)

        // ⌘ reveals instead of opening.
        let reveal = item("Reveal in Finder  ·  \(name)",
                          action: #selector(revealRecording(_:)))
        reveal.representedObject = url
        reveal.isAlternate = true
        reveal.keyEquivalentModifierMask = [.command]
        menu.addItem(reveal)

        // ⇧ carries the GIF actions, which moved off ⌥ to make room for Delete.
        let isGIF = url.pathExtension.lowercased() == "gif"
        let convert = isGIF
            ? item("Edit Frames  ·  \(name)", action: #selector(editRecording(_:)))
            : item("Convert to GIF  ·  \(name)", action: #selector(convertRecording(_:)))
        convert.representedObject = url
        convert.isAlternate = true
        convert.keyEquivalentModifierMask = [.shift]
        if !isGIF { convert.isEnabled = state.phase == .idle }
        menu.addItem(convert)
    }

    /// One entry per mode — never more. Normally each opens its picker;
    /// while ⌥ is held they switch to what that mode last recorded and start
    /// immediately.
    ///
    /// NSMenuItem.isAlternate is not usable here: it only pairs items that
    /// share a key equivalent, and these carry their own shortcuts. The ⌥
    /// state is polled instead (menu tracking runs its own event loop, so a
    /// timer in .common mode is what reliably sees the modifier).
    private struct ModeEntry {
        let item: NSMenuItem
        let plainTitle: String
        let configuredTitle: String?
        let pickerAction: Selector
        let instantAction: Selector
    }

    private func addModeItems(to menu: NSMenu) {
        modeEntries.removeAll()

        var isWindowDefault = false, isPinnedDefault = false
        var isRegionDefault = false, isDisplayDefault = false
        switch state.defaultMode {
        case .window: isWindowDefault = true
        case .pinned: isPinnedDefault = true
        case .region: isRegionDefault = true
        case .display: isDisplayDefault = true
        }

        func add(plain: String,
                 configured: String?,
                 pickerAction: Selector,
                 instantAction: Selector,
                 shortcut: KeyboardShortcuts.Name,
                 isDefault: Bool) {
            let entry = item(plain, action: pickerAction)
            entry.isEnabled = permissions.granted
            entry.state = isDefault ? .on : .off
            entry.setShortcut(for: shortcut)
            menu.addItem(entry)
            modeEntries.append(ModeEntry(item: entry,
                                         plainTitle: plain,
                                         configuredTitle: configured,
                                         pickerAction: pickerAction,
                                         instantAction: instantAction))
        }

        // Focused window is always "whatever is focused right now" — there is
        // nothing to remember and nothing to pick.
        add(plain: "Focused Window", configured: nil,
            pickerAction: #selector(recordFocused), instantAction: #selector(recordFocused),
            shortcut: .recordFocusedWindow, isDefault: isWindowDefault)

        add(plain: "Selected Window…",
            configured: ModeMemory.pinned.map { "Selected Window — \(Self.windowLabel(for: $0))" },
            pickerAction: #selector(recordPinned),
            instantAction: #selector(recordPinnedRemembered),
            shortcut: .recordSelectedWindow, isDefault: isPinnedDefault)

        add(plain: "Screen Region…",
            configured: ModeMemory.usableRegion().map { "Screen Region — \(Self.regionLabel(for: $0.1))" },
            pickerAction: #selector(recordRegion),
            instantAction: #selector(recordRegionRemembered),
            shortcut: .recordRegion, isDefault: isRegionDefault)

        add(plain: "Full Screen…",
            configured: ModeMemory.usableDisplay().map { "Full Screen — \(Self.screenLabel(for: $0))" },
            pickerAction: #selector(pickScreen),
            instantAction: #selector(recordFullScreenRemembered),
            shortcut: .recordFullScreen, isDefault: isDisplayDefault)

        applyAlt(NSEvent.modifierFlags.contains(.option))
    }

    /// Swap the four titles/actions in place as ⌥ goes down and up.
    private func applyAlt(_ alt: Bool) {
        guard altActive != alt || !hasAppliedAlt else {
            hasAppliedAlt = true
            return
        }
        altActive = alt
        hasAppliedAlt = true
        for entry in modeEntries {
            if alt, let configured = entry.configuredTitle {
                entry.item.title = configured
                entry.item.action = entry.instantAction
            } else {
                entry.item.title = entry.plainTitle
                entry.item.action = entry.pickerAction
            }
        }
    }

    private func startAltTracking() {
        stopAltTracking()
        hasAppliedAlt = false
        applyAlt(NSEvent.modifierFlags.contains(.option))
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyAlt(NSEvent.modifierFlags.contains(.option))
            }
        }
        // .common so it keeps firing while the menu tracks events.
        RunLoop.current.add(timer, forMode: .common)
        altTimer = timer
    }

    private func stopAltTracking() {
        altTimer?.invalidate()
        altTimer = nil
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

    @objc private func cancelCountdown() { state.cancelCountdown() }

    @objc private func stopFromMenu() { state.stopRecording() }

    @objc private func togglePauseFromMenu() { state.togglePause() }

    @objc private func openRecording(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if NSEvent.modifierFlags.contains(.command) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            RecordingOpener.open(url)
        }
    }

    @objc private func convertRecording(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        state.convertToGIF(url)
    }

    @objc private func revealRecording(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// No confirmation: on permanent storage the file goes to the Trash and is
    /// recoverable, and /tmp recordings are disposable by design. Clear All
    /// still confirms, because that one is not reversible per-file.
    @objc private func deleteRecording(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        store.delete(url)
    }

    @objc private func editRecording(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        windowManager.showGIFEditor(url: url)
    }

    private enum ClearScope { case all, olderOnly }

    @objc private func clearAll() { clear(scope: .all) }
    @objc private func clearOlderRecordings() { clear(scope: .olderOnly) }

    private func clear(scope: ClearScope) {
        // /tmp deletes immediately (throwaway by design); permanent storage
        // confirms, then Trashes (recoverable) rather than deletes. The
        // count/size are re-read at click time, not menu-build time.
        let toTrash = Prefs.storageChoice != "tmp"
        let older = store.olderRecordings()
        let count = older.count + (scope == .all ? store.recordings.count : 0)
        let bytes = older.reduce(0) { $0 + $1.bytes }
            + (scope == .all ? store.totalBytes : 0)
        if toTrash, count > 0 {
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            let alert = NSAlert()
            alert.messageText = count == 1
                ? "Move 1 recording to the Trash?"
                : "Move \(count) recordings to the Trash?"
            alert.informativeText = scope == .all
                ? "Every recording screc lists in \(RecordingStore.directory.path) "
                    + "— \(size) in total — will be moved to the Trash."
                : "The \(count == 1 ? "older recording" : "\(count) older recordings") in "
                    + "\(RecordingStore.directory.path) — \(size) in total — will be "
                    + "moved to the Trash. The recent recordings stay."
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        switch scope {
        case .all: store.clearAll(toTrash: toTrash)
        case .olderOnly: store.clearOlder(toTrash: toTrash)
        }
    }

    @objc private func openStorageFolder() {
        NSWorkspace.shared.open(RecordingStore.directory)
    }
    @objc private func openOnboarding() { windowManager.showOnboarding() }
    @objc private func openSettings() { windowManager.showSettings() }
    @objc private func openAbout() { windowManager.showOnboarding() }
    @objc private func quit() { NSApp.terminate(nil) }
}
