import KeyboardShortcuts
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var permissions: PermissionManager
    @AppStorage(DefaultsKey.showsCursor) private var showsCursor = true
    @AppStorage(DefaultsKey.captureSystemAudio) private var captureSystemAudio = true
    @AppStorage(DefaultsKey.discardShortRecordings) private var discardShortRecordings = true
    @AppStorage(DefaultsKey.notifyOnFinish) private var notifyOnFinish = true
    @AppStorage(DefaultsKey.storageChoice) private var storageChoice = "tmp"
    @AppStorage(DefaultsKey.customStoragePath) private var customStoragePath = ""
    @AppStorage(DefaultsKey.fileNamePattern) private var fileNamePattern = "screc-{date}-{time}"
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

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
            Image(systemName: "record.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("sčrec")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
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
            Section("Permissions") {
                LabeledContent("Screen Recording") {
                    if permissions.granted {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Open System Settings…") {
                            permissions.openSystemSettings()
                        }
                    }
                }
            }

            Section("Recording") {
                Toggle("Show mouse cursor", isOn: $showsCursor)
                Toggle("Capture system audio", isOn: $captureSystemAudio)
                Toggle("Discard recordings shorter than 3 seconds",
                       isOn: $discardShortRecordings)
            }

            Section("Output Preset") {
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
                Section("Format Settings") {
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
                                    IntField(value: $config.videoBitrateKbps, width: 72)
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

                        DisclosureGroup("Advanced") {
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
                                        IntField(value: $config.keyframeSeconds, width: 40)
                                        Stepper("", value: $config.keyframeSeconds, in: 1...10)
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
                            .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }

            Section("Storage") {
                Picker("Location", selection: $storageChoice) {
                    Text("/tmp/screc — cleared on reboot").tag("tmp")
                    Text("~/Movies/screc").tag("movies")
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
                KeyboardShortcuts.Recorder("Start/stop recording", name: .toggleRecording)
                Toggle("Launch at login", isOn: launchAtLoginBinding)
                Toggle("Notify when a recording is saved", isOn: $notifyOnFinish)
            }

            Section("About") {
                LabeledContent("Version", value: versionString)
                LabeledContent("Author", value: "Philipp Holzschneider")
                Text("""
                **License** — Binary distributions obtained through Apple's \
                App Store are licensed under their App Store purchase terms. \
                The source code is MIT-licensed for contributors: if you \
                forked or cloned the repository and built sčrec yourself, you \
                agree to offer future code changes back upstream via pull \
                requests to the repository you originally obtained it from.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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

    private var presetPicker: some View {
        Picker("", selection: presetSelection) {
            ForEach(PresetLibrary.videoBuiltins) { preset in
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

    private func chooseCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
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

    // Linked resolution: writing either field mirrors into the other.
    private var maxWidthBinding: Binding<Int?> {
        Binding(
            get: { config.maxWidth },
            set: { value in
                config.maxWidth = value
                if config.resolutionLinked { config.maxHeight = value }
            })
    }

    private var maxHeightBinding: Binding<Int?> {
        Binding(
            get: { config.maxHeight },
            set: { value in
                config.maxHeight = value
                if config.resolutionLinked { config.maxWidth = value }
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
