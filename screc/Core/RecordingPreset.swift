import Foundation

/// The fully customizable output configuration — the single source of truth
/// consumed by the recorder engine and the GIF converter. Presets are just
/// named copies of this struct; the settings UI shows "Custom" whenever the
/// live config matches no preset.
///
/// Decoding is lenient (defaults for missing keys) so configs persisted by
/// older builds keep working as fields get added.
struct RecordingConfig: Codable, Equatable {
    enum Format: String, Codable, CaseIterable {
        case mp4, hevc, gif

        var label: String {
            switch self {
            case .mp4: "MP4 (H.264)"
            case .hevc: "MP4 (HEVC)"
            case .gif: "GIF"
            }
        }
    }

    var format: Format = .mp4
    /// UI: the chain button next to the resolution fields — linked keeps both
    /// caps identical (a long-edge cap, effectively).
    var resolutionLinked = true
    var forceAspect = false
    var aspectRatio = "16:9"
    /// Resolution CAPS in pixels; nil = native. Aspect ratio and the native
    /// size of the captured content decide the actual output resolution —
    /// caps only ever scale down.
    var maxWidth: Int? = 1280
    var maxHeight: Int? = 1280
    var maxFPS = 30

    // MP4/HEVC
    var videoBitrateKbps = 1200
    var audioBitrateKbps = 96
    var audioChannels = 2
    var keyframeSeconds = 4
    var h264Profile = "high" // baseline | main | high
    var h264CABAC = true
    var allowBFrames = true

    // GIF
    var gifLoopForever = true
    /// 0 = off; 0.1…1 = CIDither intensity applied before quantization
    /// (reduces banding on gradients at the cost of visible noise).
    var gifDitherIntensity = 0.0

    static let aspectPresets = [
        "1:1", "4:3", "3:2", "16:10", "16:9", "8:3", "21:9",
        "2:3", "3:4", "10:16", "9:16",
    ]

    /// Width ÷ height when Force Aspect Ratio is active, else nil.
    var aspectValue: Double? {
        guard forceAspect else { return nil }
        let parts = aspectRatio.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return parts[0] / parts[1]
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(Format.self, forKey: .format) ?? .mp4
        resolutionLinked = try c.decodeIfPresent(Bool.self, forKey: .resolutionLinked) ?? true
        forceAspect = try c.decodeIfPresent(Bool.self, forKey: .forceAspect) ?? false
        aspectRatio = try c.decodeIfPresent(String.self, forKey: .aspectRatio) ?? "16:9"
        maxWidth = try c.decodeIfPresent(Int.self, forKey: .maxWidth)
        maxHeight = try c.decodeIfPresent(Int.self, forKey: .maxHeight)
        maxFPS = try c.decodeIfPresent(Int.self, forKey: .maxFPS) ?? 30
        videoBitrateKbps = try c.decodeIfPresent(Int.self, forKey: .videoBitrateKbps) ?? 1200
        audioBitrateKbps = try c.decodeIfPresent(Int.self, forKey: .audioBitrateKbps) ?? 96
        audioChannels = try c.decodeIfPresent(Int.self, forKey: .audioChannels) ?? 2
        keyframeSeconds = try c.decodeIfPresent(Int.self, forKey: .keyframeSeconds) ?? 4
        h264Profile = try c.decodeIfPresent(String.self, forKey: .h264Profile) ?? "high"
        h264CABAC = try c.decodeIfPresent(Bool.self, forKey: .h264CABAC) ?? true
        allowBFrames = try c.decodeIfPresent(Bool.self, forKey: .allowBFrames) ?? true
        gifLoopForever = try c.decodeIfPresent(Bool.self, forKey: .gifLoopForever) ?? true
        gifDitherIntensity = try c.decodeIfPresent(Double.self, forKey: .gifDitherIntensity) ?? 0
        // Configs persisted before the chain existed used a width-only cap.
        if resolutionLinked, maxHeight == nil {
            maxHeight = maxWidth
        }
    }

    static let tinyMP4: RecordingConfig = {
        var c = RecordingConfig()
        c.maxWidth = 800
        c.maxHeight = 800
        c.maxFPS = 15
        c.videoBitrateKbps = 600
        c.audioBitrateKbps = 64
        return c
    }()

    static let smallMP4: RecordingConfig = {
        var c = RecordingConfig()
        c.maxWidth = 1280
        c.maxHeight = 1280
        return c
    }()

    static let mediumMP4: RecordingConfig = {
        var c = RecordingConfig()
        c.maxWidth = 1920
        c.maxHeight = 1920
        c.videoBitrateKbps = 3000
        c.audioBitrateKbps = 128
        return c
    }()

    static let largeMP4: RecordingConfig = {
        var c = RecordingConfig()
        c.maxWidth = 2560
        c.maxHeight = 2560
        c.videoBitrateKbps = 6000
        c.audioBitrateKbps = 128
        return c
    }()

    static let compactHEVC: RecordingConfig = {
        var c = RecordingConfig()
        c.format = .hevc
        c.maxWidth = 1920
        c.maxHeight = 1920
        c.videoBitrateKbps = 1750
        c.audioBitrateKbps = 128
        return c
    }()

    static let masterHEVC: RecordingConfig = {
        var c = RecordingConfig()
        c.format = .hevc
        c.maxWidth = nil
        c.maxHeight = nil
        c.maxFPS = 60
        c.videoBitrateKbps = 10000
        c.audioBitrateKbps = 192
        return c
    }()

    static let gifSmall: RecordingConfig = {
        var c = RecordingConfig()
        c.format = .gif
        c.maxWidth = 480
        c.maxHeight = 480
        c.maxFPS = 10
        return c
    }()

    static let gif: RecordingConfig = {
        var c = RecordingConfig()
        c.format = .gif
        c.maxWidth = 640
        c.maxHeight = 640
        c.maxFPS = 12
        return c
    }()

    static let gifLarge: RecordingConfig = {
        var c = RecordingConfig()
        c.format = .gif
        c.maxWidth = 800
        c.maxHeight = 800
        c.maxFPS = 15
        return c
    }()
}

struct RecordingPresetDef: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var config: RecordingConfig
}

enum PresetLibrary {
    static let videoBuiltins: [RecordingPresetDef] = [
        .init(id: "builtin.tiny-mp4", name: "Tiny MP4", config: .tinyMP4),
        .init(id: "builtin.small-mp4", name: "Small MP4", config: .smallMP4),
        .init(id: "builtin.medium-mp4", name: "Medium MP4", config: .mediumMP4),
        .init(id: "builtin.large-mp4", name: "Large MP4", config: .largeMP4),
        .init(id: "builtin.compact-hevc", name: "Compact HEVC", config: .compactHEVC),
        .init(id: "builtin.master-hevc", name: "Master HEVC (native)", config: .masterHEVC),
    ]

    static let gifBuiltins: [RecordingPresetDef] = [
        .init(id: "builtin.gif-small", name: "GIF Small", config: .gifSmall),
        .init(id: "builtin.gif", name: "GIF Medium", config: .gif),
        .init(id: "builtin.gif-large", name: "GIF Large", config: .gifLarge),
    ]

    static let builtins: [RecordingPresetDef] = videoBuiltins + gifBuiltins

    /// The configuration recordings actually use.
    static var currentConfig: RecordingConfig {
        if let data = UserDefaults.standard.data(forKey: DefaultsKey.currentRecordingConfig),
           let config = try? JSONDecoder().decode(RecordingConfig.self, from: data) {
            return config
        }
        // Migrate from the pre-M3.5 preset-id key.
        switch UserDefaults.standard.string(forKey: DefaultsKey.outputPreset) {
        case "medium-mp4": return .mediumMP4
        case "hevc": return .compactHEVC
        case "gif": return .gif
        default: return .smallMP4
        }
    }

    static func setCurrent(_ config: RecordingConfig) {
        let data = (try? JSONEncoder().encode(config)) ?? Data()
        UserDefaults.standard.set(data, forKey: DefaultsKey.currentRecordingConfig)
    }

    static func customPresets() -> [RecordingPresetDef] {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.customPresets),
              let list = try? JSONDecoder().decode([RecordingPresetDef].self, from: data)
        else { return [] }
        return list
    }

    static func persistCustom(_ list: [RecordingPresetDef]) {
        let data = (try? JSONEncoder().encode(list)) ?? Data()
        UserDefaults.standard.set(data, forKey: DefaultsKey.customPresets)
    }
}
