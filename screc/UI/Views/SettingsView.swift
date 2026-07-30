import AVFoundation
import KeyboardShortcuts
import ServiceManagement
import SwiftUI
@preconcurrency import UserNotifications

struct SettingsView: View {
    @ObservedObject var permissions: PermissionManager
    @AppStorage(DefaultsKey.showsCursor) private var showsCursor = true
    @AppStorage(DefaultsKey.captureSystemAudio) private var captureSystemAudio = true
    @AppStorage(DefaultsKey.discardShortRecordings) private var discardShortRecordings = true
    @AppStorage(DefaultsKey.notifyOnFinish) private var notifyOnFinish = true
    @AppStorage(DefaultsKey.countdownEnabled) private var countdownEnabled = false
    @AppStorage(DefaultsKey.micEnabled) private var micEnabled = false
    @AppStorage(DefaultsKey.micDeviceID) private var micDeviceID = ""
    @AppStorage(DefaultsKey.micGain) private var micGain = 1.0
    @AppStorage(DefaultsKey.doubleCursorSize) private var doubleCursorSize = false
    @AppStorage(DefaultsKey.showsMouseClicks) private var showsMouseClicks = false
    @AppStorage(DefaultsKey.showsMouseScroll) private var showsMouseScroll = false
    @AppStorage(DefaultsKey.showsKeyStrokes) private var showsKeyStrokes = false
    @AppStorage(DefaultsKey.showsKeyCombinations) private var showsKeyCombinations = false
    @State private var keyMonitoringGranted = InputMonitor.keyAccessGranted
    @StateObject private var micMonitor = MicLevelMonitor()
    @State private var micDevices: [MicDevices.Device] = []
    @State private var micDenied = false
    @State private var advancedExpanded = false
    @AppStorage(DefaultsKey.storageChoice) private var storageChoice = "tmp"
    @AppStorage(DefaultsKey.customStoragePath) private var customStoragePath = ""
    @AppStorage(DefaultsKey.fileNamePattern) private var fileNamePattern = "screc-{date}-{time}"
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var notificationsDenied = false

    /// The live configuration (persisted on every change).
    @State private var config = PresetLibrary.currentConfig
    @State private var customPresets = PresetLibrary.customPresets()

    /// Explicit picker selection: a preset id, or "custom". Built-in presets
    /// hide the Format Settings section; custom presets and "Custom" expand
    /// it (custom presets load their values for editing).
    @State private var selection: String = {
        let current = PresetLibrary.currentConfig
        return (PresetLibrary.builtins + PresetLibrary.customPresets())
            .first { $0.config == current }?.id ?? "custom"
    }()

    @State private var presetName: String = {
        let current = PresetLibrary.currentConfig
        let customs = PresetLibrary.customPresets()
        if let match = customs.first(where: { $0.config == current }) {
            return match.name
        }
        let names = Set(customs.map(\.name))
        var n = 1
        while names.contains("Custom Preset #\(n)") { n += 1 }
        return "Custom Preset #\(n)"
    }()

    private var allPresets: [RecordingPresetDef] {
        PresetLibrary.builtins + customPresets
    }

    private var formatSettingsVisible: Bool {
        selection == "custom" || selection.hasPrefix("custom.")
    }

    /// The custom preset the name field currently points at, if any
    /// (built-ins are never updated or deleted).
    private var existingCustomPreset: RecordingPresetDef? {
        let trimmed = presetName.trimmingCharacters(in: .whitespaces)
        return customPresets.first { $0.name == trimmed }
    }

    /// Saving a custom preset under a built-in's name would put two identical
    /// labels in the picker.
    private var nameShadowsBuiltin: Bool {
        let trimmed = presetName.trimmingCharacters(in: .whitespaces).lowercased()
        return PresetLibrary.builtins.contains { $0.name.lowercased() == trimmed }
    }

    private var presetSelection: Binding<String> {
        Binding(
            get: { selection },
            set: { id in
                selection = id
                if id == "custom" {
                    // Keep the last preset's values as the editing baseline.
                    presetName = uniquePresetName()
                } else if let preset = allPresets.first(where: { $0.id == id }) {
                    config = preset.config
                    bitrateCustomMode =
                        !Self.bitratePresets.contains(preset.config.videoBitrateKbps)
                    if id.hasPrefix("custom.") {
                        presetName = preset.name
                    }
                }
            })
    }

    /// The mic level slider and the input meter share this width so the two
    /// rows line up under each other.
    private static let micControlWidth: CGFloat = 160

    private var needsKeyMonitoring: Bool { showsKeyStrokes || showsKeyCombinations }

    private var anyInputVisualization: Bool {
        (showsCursor && doubleCursorSize) || showsMouseClicks || showsMouseScroll
            || needsKeyMonitoring
    }

    private func refreshKeyMonitoringStatus() {
        keyMonitoringGranted = InputMonitor.keyAccessGranted
    }

    private var videoFPSOptions: [Int] { [15, 24, 30, 60] }
    private var gifFPSOptions: [Int] { [5, 10, 12, 15] }
    private static let bitratePresets = [500, 800, 1200, 2000, 3000, 5000, 8000, 12000]

    /// "Custom" chosen in the bitrate popup: the editable field is shown and
    /// drives the value.
    @State private var bitrateCustomMode: Bool =
        !SettingsView.bitratePresets.contains(PresetLibrary.currentConfig.videoBitrateKbps)

    private var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            settingsForm
        }
        .frame(width: 520, height: formatSettingsVisible ? 760 : 560)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    NSWorkspace.shared.open(BuildFlavor.siteURL)
                } label: {
                    HStack(alignment: .lastTextBaseline, spacing: 7) {
                        Text("●")
                            .font(.system(size: 15))
                            .foregroundStyle(.red)
                        Text("screc")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.plain)
                .help("Open screc.app")
                Text("One click in the menu bar → a small, share-ready recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("v\(versionString)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var settingsForm: some View {
        Form {
            // Everything about capturing the screen: the access it needs,
            // how it captures, and what comes out.
            Section("Screen Recording") {
                LabeledContent("Permission") {
                    if permissions.granted {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Open System Settings…") {
                            permissions.openSystemSettings()
                        }
                    }
                }
                Text("macOS re-confirms screen-recording consent periodically — the occasional system prompt about screc comes from the OS, not from screc.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text("Preset")
                    Spacer()
                    if selection != "custom" {
                        Text(config.shortSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(config.detailedSummary)
                    }
                    presetPicker
                }
            }

            if formatSettingsVisible {
                Section("Format") {
                    Picker("Video format", selection: $config.format) {
                        ForEach(RecordingConfig.Format.allCases, id: \.self) { format in
                            Text(format.label).tag(format)
                        }
                    }

                    LabeledContent("Force aspect ratio") {
                        HStack(spacing: 10) {
                            Toggle("", isOn: $config.forceAspect)
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                            // Intrinsic size: a fixed frame centers the popup
                            // inside it, pushing the chevron off the trailing
                            // edge where every other picker sits.
                            Picker("", selection: $config.aspectRatio) {
                                ForEach(RecordingConfig.aspectPresets, id: \.self) { ratio in
                                    Text(ratio).tag(ratio)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .disabled(!config.forceAspect)
                        }
                    }

                    LabeledContent("Max resolution") {
                        HStack(spacing: 6) {
                            Button {
                                config.resolutionLinked.toggle()
                                if config.resolutionLinked {
                                    config.maxHeight = config.maxWidth
                                }
                            } label: {
                                if config.resolutionLinked {
                                    Image(systemName: "link")
                                } else {
                                    BrokenLinkIcon()
                                }
                            }
                            .buttonStyle(.borderless)
                            .help(config.resolutionLinked
                                  ? "Linked: both caps stay identical"
                                  : "Unlinked: caps set independently")
                            OptionalIntField(value: maxWidthBinding, width: 64)
                            Text("×")
                                .foregroundStyle(.secondary)
                            OptionalIntField(value: maxHeightBinding, width: 64)
                            Text("px")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Picker("Max frame rate", selection: $config.maxFPS) {
                        ForEach(config.format == .gif ? gifFPSOptions : videoFPSOptions,
                                id: \.self) { fps in
                            Text("\(fps) fps").tag(fps)
                        }
                    }

                    if config.format == .gif {
                        Toggle("Loop forever", isOn: $config.gifLoopForever)
                        Toggle("Dithering (reduces banding, adds noise)", isOn: ditherEnabled)
                        if config.gifDitherIntensity > 0 {
                            LabeledContent("Dither intensity") {
                                Slider(value: $config.gifDitherIntensity, in: 0.1...1)
                                    .frame(width: 160)
                            }
                        }
                        Text("Palette optimization and multi-pass encoding need the gifski engine — a possible future upgrade; the built-in encoder uses ImageIO.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Video bitrate") {
                            HStack(spacing: 6) {
                                if bitrateCustomMode {
                                    IntField(value: videoBitrateBinding, width: 72)
                                    Text("kbit/s")
                                        .foregroundStyle(.secondary)
                                }
                                Picker("", selection: bitrateSelection) {
                                    ForEach(Self.bitratePresets, id: \.self) { kbps in
                                        Text("\(kbps) kbit/s").tag(kbps)
                                    }
                                    Divider()
                                    Text("Custom").tag(-1)
                                }
                                .labelsHidden()
                                .fixedSize()
                            }
                        }
                        Picker("Audio bitrate", selection: $config.audioBitrateKbps) {
                            Text("64 kbit/s").tag(64)
                            Text("96 kbit/s").tag(96)
                            Text("128 kbit/s").tag(128)
                            Text("192 kbit/s").tag(192)
                        }

                        advancedHeader
                        if advancedExpanded {
                            VStack(spacing: 0) {
                                if config.format == .mp4 {
                                    LabeledContent("H.264 profile") {
                                        Picker("", selection: $config.h264Profile) {
                                            Text("Baseline (max compatibility)").tag("baseline")
                                            Text("Main").tag("main")
                                            Text("High (best compression)").tag("high")
                                        }
                                        .labelsHidden()
                                        .fixedSize()
                                    }
                                    .padding(.vertical, 8)
                                    Divider()
                                    LabeledContent("CABAC entropy coding") {
                                        Toggle("", isOn: $config.h264CABAC)
                                            .labelsHidden()
                                            .disabled(config.h264Profile == "baseline")
                                    }
                                    .padding(.vertical, 8)
                                    Divider()
                                }
                                LabeledContent("Allow B-frames (frame reordering)") {
                                    Toggle("", isOn: $config.allowBFrames)
                                        .labelsHidden()
                                }
                                .padding(.vertical, 8)
                                Divider()
                                LabeledContent("Keyframe every k seconds") {
                                    HStack(spacing: 6) {
                                        Text("k =")
                                            .foregroundStyle(.secondary)
                                        IntField(value: keyframeBinding, width: 40)
                                        Stepper("", value: keyframeBinding, in: 1...10)
                                            .labelsHidden()
                                    }
                                }
                                .padding(.vertical, 8)
                                Divider()
                                LabeledContent("Audio channels") {
                                    Picker("", selection: $config.audioChannels) {
                                        Text("Mono").tag(1)
                                        Text("Stereo").tag(2)
                                    }
                                    .labelsHidden()
                                    .fixedSize()
                                }
                                .padding(.vertical, 8)
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Text("Preset name")
                        Spacer()
                        NameField(text: $presetName)
                            .frame(width: 180)
                        if let existing = existingCustomPreset {
                            // Same footprint as the single save button.
                            HStack(spacing: 4) {
                                Button(role: .destructive) {
                                    deletePreset(existing)
                                } label: {
                                    Text("Delete").frame(maxWidth: .infinity)
                                }
                                Button {
                                    savePreset()
                                } label: {
                                    Text("Update").frame(maxWidth: .infinity)
                                }
                            }
                            .frame(width: 150)
                        } else {
                            Button {
                                savePreset()
                            } label: {
                                Text("Save as new Preset").frame(maxWidth: .infinity)
                            }
                            .frame(width: 150)
                            .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty
                                      || nameShadowsBuiltin)
                            .help(nameShadowsBuiltin
                                  ? "A built-in preset already has this name"
                                  : "")
                        }
                    }
                }
            }

            Section("Sound") {
                Toggle("Record System Audio", isOn: $captureSystemAudio)
                // Plain binding: .onChange(of: micEnabled) does the asking.
                Toggle("Record Microphone", isOn: $micEnabled)
                if micEnabled {
                    if micDenied {
                        HStack(spacing: 8) {
                            Text("Microphone access for screc is turned off in System Settings.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Button("Open System Settings…") {
                                NSWorkspace.shared.open(URL(string:
                                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                            }
                            .controlSize(.small)
                        }
                    } else {
                        Picker("Input device", selection: $micDeviceID) {
                            Text("System Default").tag("")
                            if !micDevices.isEmpty { Divider() }
                            ForEach(micDevices) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                        LabeledContent("Input meter") {
                            MicMeterBar(level: micMonitor.level,
                                        width: Self.micControlWidth)
                        }
                        LabeledContent("Microphone level") {
                            // Percentage left of the slider; the slider and
                            // the meter share a width, so both rows line up
                            // on the trailing edge LabeledContent gives them.
                            HStack(spacing: 8) {
                                Text("\(Int(micGain * 100)) %")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .trailing)
                                Slider(value: $micGain, in: 0...1)
                                    .frame(width: Self.micControlWidth)
                            }
                        }
                    }
                    Text("Mixed with the system audio when the recording stops. GIF recordings have no audio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Input") {
                Toggle("Show mouse cursor", isOn: $showsCursor)
                Toggle("Double mouse cursor size", isOn: $doubleCursorSize)
                    .disabled(!showsCursor)
                Toggle("Show mouse clicks", isOn: $showsMouseClicks)
                Toggle("Show mouse scroll", isOn: $showsMouseScroll)
                Toggle("Show key strokes", isOn: $showsKeyStrokes)
                Toggle("Show key combinations", isOn: $showsKeyCombinations)
                if needsKeyMonitoring && !keyMonitoringGranted {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Showing keys needs the Input Monitoring permission.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        HStack(spacing: 8) {
                            Button("Allow Input Monitoring…") {
                                InputMonitor.requestKeyAccess()
                                refreshKeyMonitoringStatus()
                            }
                            .controlSize(.small)
                            Button("Open System Settings…") {
                                InputMonitor.openInputMonitoringSettings()
                            }
                            .controlSize(.small)
                        }
                    }
                }
                if anyInputVisualization {
                    Text("Drawn into full-screen and region recordings. A recording scoped to a single window composites only that window, so overlays cannot appear in Focused Window mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Hotkeys") {
                ForEach(KeyboardShortcuts.Name.allRecordingShortcuts, id: \.name) { entry in
                    ShortcutRow(name: entry.name, label: entry.label)
                }
                Text("Each mode hotkey starts that mode with what it last recorded; any of them also stops a running recording. Hover a shortcut to clear it back to the default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Storage") {
                Picker("Location", selection: $storageChoice) {
                    if RecordingStore.isSandboxed {
                        // The sandbox has no /tmp and no blanket ~/Movies
                        // access; the container temp mimics the boot wipe.
                        Text("Temporary — cleared after restart").tag("tmp")
                    } else {
                        Text("/tmp/screc — cleared on reboot").tag("tmp")
                        Text("~/Movies/screc").tag("movies")
                    }
                    Text("Custom folder").tag("custom")
                }
                if storageChoice == "custom" {
                    LabeledContent("Folder") {
                        HStack(spacing: 8) {
                            Text(customStoragePath.isEmpty ? "not set" : customStoragePath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Button("Choose…") { chooseCustomFolder() }
                        }
                    }
                }
                LabeledContent("File name") {
                    NameField(text: $fileNamePattern)
                        .frame(width: 220)
                }
                Text("Tokens: {date} → 20260726 · {time} → 143005 · applies to new recordings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Discard recordings shorter than 3 seconds",
                       isOn: $discardShortRecordings)
                Toggle("Countdown before recording (3 s)", isOn: $countdownEnabled)
                Toggle("Launch at login", isOn: launchAtLoginBinding)
                // Kept last: its "notifications are off" warning appears
                // directly beneath it.
                Toggle("Notify when a recording is saved", isOn: $notifyOnFinish)
                if notifyOnFinish && notificationsDenied {
                    HStack(spacing: 8) {
                        Text("Notifications for screc are turned off in System Settings, so no banner will appear.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Open System Settings…") {
                            NSWorkspace.shared.open(URL(string:
                                "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                        .controlSize(.small)
                    }
                }
            }
            .task { await refreshNotificationStatus() }

            Section("About") {
                LabeledContent("Version", value: versionString)
                LabeledContent("Author", value: "Philipp Holzschneider · Kleinzeug")
                if BuildFlavor.showsSourceLinks {
                    LabeledContent("Source") {
                        Link("github.com/kleinzeug/screc",
                             destination: BuildFlavor.repositoryURL)
                    }
                    LabeledContent("Support") {
                        Link("Buy me a coffee ☕", destination: BuildFlavor.coffeeURL)
                    }
                }
                Text("""
                **License** — The source is MIT-licensed: clone it, build it, \
                change it. If you improve screc, sending the change back \
                upstream as a pull request is appreciated — a request, not a \
                condition.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                Text("""
                Binaries distributed through the Mac App Store are covered by \
                Apple's standard End User License Agreement.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // A "movies" choice can't exist in the sandboxed flavor (no
            // blanket ~/Movies access) — normalize a migrated preference.
            if RecordingStore.isSandboxed && storageChoice == "movies" {
                storageChoice = "tmp"
            }
            // Already-enabled section with an undecided permission (e.g.
            // enabled before the entitlement existed): ask now.
            requestMicAccessIfNeeded()
        }
        .onDisappear { micMonitor.stop() }
        .onChange(of: micEnabled) { requestMicAccessIfNeeded() }
        .onChange(of: micDeviceID) { refreshMicStatus() }
        // Coming back from System Settings must update the state in place.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshMicStatus()
            refreshKeyMonitoringStatus()
            Task { await refreshNotificationStatus() }
        }
        .onChange(of: config) {
            PresetLibrary.setCurrent(config)
        }
        .onChange(of: config.format) {
            // Keep fps valid when the option list switches with the format.
            let options = config.format == .gif ? gifFPSOptions : videoFPSOptions
            if !options.contains(config.maxFPS) {
                config.maxFPS = config.format == .gif ? 12 : 30
            }
        }
    }

    /// Hand-rolled disclosure row. DisclosureGroup does not reliably
    /// re-render inside `.formStyle(.grouped)` on macOS — its content stayed
    /// hidden until some unrelated change invalidated the view — so the
    /// chevron, the hit target and the conditional content are all explicit.
    /// The whole row is the target, not just the chevron.
    private var advancedHeader: some View {
        Button {
            advancedExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(advancedExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.15), value: advancedExpanded)
                Text("Advanced")
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var presetPicker: some View {
        Picker("", selection: presetSelection) {
            ForEach(PresetLibrary.mp4Builtins) { preset in
                Text(preset.name).tag(preset.id)
            }
            Divider()
            ForEach(PresetLibrary.hevcBuiltins) { preset in
                Text(preset.name).tag(preset.id)
            }
            Divider()
            ForEach(PresetLibrary.gifBuiltins) { preset in
                Text(preset.name).tag(preset.id)
            }
            if !customPresets.isEmpty {
                Divider()
                ForEach(customPresets) { preset in
                    Text(preset.name).tag(preset.id)
                }
            }
            Divider()
            Text("Custom").tag("custom")
        }
        .labelsHidden()
        .fixedSize()
    }

    // MARK: - General & storage

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { enabled in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    launchAtLogin = enabled
                } catch {
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            })
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsDenied = settings.authorizationStatus == .denied
    }

    // MARK: - Microphone

    /// Re-reads the authorization state; never prompts. Safe to call on
    /// every window activation, which is how a grant made in System Settings
    /// reaches the UI without a relaunch.
    private func refreshMicStatus() {
        guard micEnabled else {
            micMonitor.stop()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micDenied = false
            micDevices = MicDevices.all()
            micMonitor.start(deviceUID: micDeviceID)
        case .notDetermined:
            micDenied = false // nothing refused yet — enabling does the asking
            micMonitor.stop()
        default:
            micDenied = true
            micMonitor.stop()
        }
    }

    /// The section asks for permission only when it is enabled (per spec),
    /// and only while the decision is still open.
    private func requestMicAccessIfNeeded() {
        guard micEnabled else {
            micMonitor.stop()
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
            refreshMicStatus()
            return
        }
        // The async form on purpose: a completion closure written inside this
        // @MainActor view would inherit main-actor isolation, and the system
        // may deliver it on any queue — the same executor-assertion trap that
        // the audio tap in MicLevelMonitor hit.
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refreshMicStatus()
        }
    }

    private func chooseCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            // Persists path + security-scoped bookmark (the sandbox forgets
            // the NSOpenPanel grant at quit; the bookmark survives).
            RecordingStore.rememberCustomFolder(url)
            customStoragePath = url.path
        }
    }

    // MARK: - Preset management

    private func uniquePresetName() -> String {
        let names = Set(customPresets.map(\.name))
        var n = 1
        while names.contains("Custom Preset #\(n)") { n += 1 }
        return "Custom Preset #\(n)"
    }

    private func savePreset() {
        let trimmed = presetName.trimmingCharacters(in: .whitespaces)
        if let existing = existingCustomPreset,
           let index = customPresets.firstIndex(where: { $0.id == existing.id }) {
            customPresets[index].config = config
            PresetLibrary.persistCustom(customPresets)
            selection = existing.id
        } else {
            let preset = RecordingPresetDef(id: "custom.\(UUID().uuidString)",
                                            name: trimmed, config: config)
            customPresets.append(preset)
            PresetLibrary.persistCustom(customPresets)
            selection = preset.id
        }
    }

    private func deletePreset(_ preset: RecordingPresetDef) {
        customPresets.removeAll { $0.id == preset.id }
        PresetLibrary.persistCustom(customPresets)
        // Keep the values on screen as an unsaved custom baseline.
        selection = "custom"
        presetName = uniquePresetName()
    }

    // MARK: - Bindings

    // Typed values are clamped on commit: a 0 bitrate would fail the encoder
    // at the worst moment (recording start), and the keyframe field must not
    // bypass the stepper's 1…10 range.
    private var videoBitrateBinding: Binding<Int> {
        Binding(
            get: { config.videoBitrateKbps },
            set: { config.videoBitrateKbps = min(max($0, 100), 100_000) })
    }

    private var keyframeBinding: Binding<Int> {
        Binding(
            get: { config.keyframeSeconds },
            set: { config.keyframeSeconds = min(max($0, 1), 10) })
    }

    /// Zero or negative caps mean "no cap" — normalize them to nil (native).
    private static func sanitizedCap(_ value: Int?) -> Int? {
        value.flatMap { $0 > 0 ? min($0, 16384) : nil }
    }

    // Linked resolution: writing either field mirrors into the other.
    private var maxWidthBinding: Binding<Int?> {
        Binding(
            get: { config.maxWidth },
            set: { value in
                let cap = Self.sanitizedCap(value)
                config.maxWidth = cap
                if config.resolutionLinked { config.maxHeight = cap }
            })
    }

    private var maxHeightBinding: Binding<Int?> {
        Binding(
            get: { config.maxHeight },
            set: { value in
                let cap = Self.sanitizedCap(value)
                config.maxHeight = cap
                if config.resolutionLinked { config.maxWidth = cap }
            })
    }

    private var ditherEnabled: Binding<Bool> {
        Binding(
            get: { config.gifDitherIntensity > 0 },
            set: { config.gifDitherIntensity = $0 ? 0.5 : 0 })
    }

    /// Popup shows the matching preset rate, or "Custom" (tag -1) with the
    /// editable field revealed.
    private var bitrateSelection: Binding<Int> {
        Binding(
            get: {
                bitrateCustomMode || !Self.bitratePresets.contains(config.videoBitrateKbps)
                    ? -1 : config.videoBitrateKbps
            },
            set: { value in
                if value == -1 {
                    bitrateCustomMode = true
                } else {
                    bitrateCustomMode = false
                    config.videoBitrateKbps = value
                }
            })
    }
}

// MARK: - Hotkey row

/// A shortcut recorder plus an (x) that appears on hover once the shortcut
/// differs from its built-in default; clearing restores that default.
private struct ShortcutRow: View {
    let name: KeyboardShortcuts.Name
    let label: String
    @State private var hovering = false
    @State private var revision = 0

    private var isCustom: Bool {
        _ = revision // re-read after a change
        return KeyboardShortcuts.getShortcut(for: name) != name.defaultShortcut
    }

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                if isCustom && hovering {
                    Button {
                        KeyboardShortcuts.reset(name)
                        revision += 1
                    } label: {
                        Image(systemName: "x.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to the default shortcut")
                } else if isCustom {
                    // Keeps the row from shifting when the button appears.
                    Image(systemName: "x.circle.fill").opacity(0)
                }
                KeyboardShortcuts.Recorder("", name: name)
                    .onChange(of: hovering) { _, _ in revision += 1 }
            }
        }
        .onHover { hovering = $0 }
    }
}

// MARK: - Config summaries

private extension RecordingConfig {
    var shortSummary: String {
        var parts: [String] = []
        switch format {
        case .mp4: parts.append("H.264")
        case .hevc: parts.append("HEVC")
        case .gif: parts.append("GIF")
        }
        parts.append(resolutionSummary)
        parts.append("\(maxFPS) fps")
        if format != .gif {
            parts.append("\(videoBitrateKbps) kbit/s")
        }
        if forceAspect {
            parts.append(aspectRatio)
        }
        return parts.joined(separator: " · ")
    }

    var resolutionSummary: String {
        switch (maxWidth, maxHeight) {
        case (nil, nil): "native"
        case let (w?, h?) where w == h: "≤\(w) px"
        case let (w?, h?): "≤\(w)×\(h)"
        case let (w?, nil): "≤\(w) px wide"
        case let (nil, h?): "≤\(h) px tall"
        }
    }

    var detailedSummary: String {
        var lines = ["• Format: \(format.label)"]
        if forceAspect {
            lines.append("• Forced aspect ratio: \(aspectRatio)")
        }
        let resolution = switch (maxWidth, maxHeight) {
        case (nil, nil): "native"
        case let (w?, h?): "\(w) × \(h) px max\(resolutionLinked ? " (linked)" : "")"
        case let (w?, nil): "\(w) px max width"
        case let (nil, h?): "\(h) px max height"
        }
        lines.append("• Max resolution: \(resolution)")
        lines.append("• Max frame rate: \(maxFPS) fps")
        if format == .gif {
            lines.append("• Loop: \(gifLoopForever ? "forever" : "once")")
            lines.append("• Dithering: \(gifDitherIntensity > 0 ? String(format: "%.1f", gifDitherIntensity) : "off")")
        } else {
            lines.append("• Video bitrate: \(videoBitrateKbps) kbit/s")
            lines.append("• Audio: \(audioBitrateKbps) kbit/s \(audioChannels == 1 ? "mono" : "stereo")")
            lines.append("• Keyframe every \(keyframeSeconds) s")
            if format == .mp4 {
                let cabac = h264CABAC && h264Profile != "baseline" ? ", CABAC" : ""
                lines.append("• H.264 profile: \(h264Profile.capitalized)\(cabac)")
            }
            lines.append("• B-frames: \(allowBFrames ? "allowed" : "off")")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Focus-aware fields

/// Plain-style fields with a subtly visible background that darkens while
/// editing, so the editable areas are discoverable.
private struct IntField: View {
    @Binding var value: Int
    var width: CGFloat = 64
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", value: $value, format: .number)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .focused($focused)
            .frame(width: width)
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(focused ? 0.10 : 0.04)))
    }
}

private struct OptionalIntField: View {
    @Binding var value: Int?
    var width: CGFloat = 64
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", value: $value, format: .number)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .focused($focused)
            .frame(width: width)
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(focused ? 0.10 : 0.04)))
    }
}

private struct NameField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .focused($focused)
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(focused ? 0.10 : 0.04)))
    }
}

/// Live input-level bar for the microphone section.
private struct MicMeterBar: View {
    var level: Double
    var width: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(level > 0.85 ? Color.red : Color.green)
                    .frame(width: max(level > 0.01 ? 4 : 0, geo.size.width * level))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
        .frame(width: width, height: 8)
    }
}

/// SF Symbols has no broken-link glyph — draw one: two chain links at 45°
/// pulled apart.
private struct BrokenLinkIcon: View {
    var body: some View {
        Canvas { context, size in
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.rotate(by: .degrees(-45))
            let linkSize = CGSize(width: 9, height: 4.5)
            for centerX in [-5.5, 5.5] {
                let rect = CGRect(x: centerX - linkSize.width / 2,
                                  y: -linkSize.height / 2,
                                  width: linkSize.width,
                                  height: linkSize.height)
                context.stroke(Path(roundedRect: rect, cornerRadius: linkSize.height / 2),
                               with: .color(.secondary), lineWidth: 1.3)
            }
        }
        .frame(width: 16, height: 16)
    }
}
