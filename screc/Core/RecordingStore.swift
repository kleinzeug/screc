import Foundation

/// Recordings live in /tmp/screc by default: macOS wipes /private/tmp at boot
/// and a daily tmp_cleaner daemon removes stale files, so disk space frees
/// itself. The recents list is persisted in UserDefaults and validated against
/// disk, since the files can vanish underneath us by design.
@MainActor
final class RecordingStore {
    struct Recording: Codable, Equatable {
        var path: String
        var date: Date
        var bytes: Int64

        var url: URL { URL(fileURLWithPath: path) }
        var name: String { url.lastPathComponent }
    }

    /// Resolved from settings: /tmp (self-cleaning), ~/Movies/screc, or a
    /// custom folder.
    static var directory: URL {
        switch Prefs.storageChoice {
        case "movies":
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Movies/screc", isDirectory: true)
        case "custom" where !Prefs.customStoragePath.isEmpty:
            return URL(fileURLWithPath: Prefs.customStoragePath, isDirectory: true)
        default:
            return URL(fileURLWithPath: "/tmp/screc", isDirectory: true)
        }
    }

    private static let maxEntries = 10

    private(set) var recordings: [Recording] = []

    init() {
        load()
        validate()
    }

    var totalBytes: Int64 {
        recordings.reduce(0) { $0 + $1.bytes }
    }

    func newOutputURL(fileExtension: String) -> URL {
        let directory = Self.directory
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        let date = DateFormatter()
        date.dateFormat = "yyyyMMdd"
        let time = DateFormatter()
        time.dateFormat = "HHmmss"
        let now = Date()
        var name = Prefs.fileNamePattern
            .replacingOccurrences(of: "{date}", with: date.string(from: now))
            .replacingOccurrences(of: "{time}", with: time.string(from: now))
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            name = "screc-\(date.string(from: now))-\(time.string(from: now))"
        }
        return directory.appendingPathComponent("\(name).\(fileExtension)")
    }

    /// Re-read a file's size (e.g. after the GIF frame editor rewrote it).
    func updateBytes(for url: URL) {
        guard let index = recordings.firstIndex(where: { $0.path == url.path }) else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        recordings[index].bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? recordings[index].bytes
        persist()
    }

    func add(_ url: URL) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        recordings.insert(Recording(path: url.path, date: Date(), bytes: bytes), at: 0)
        while recordings.count > Self.maxEntries {
            let dropped = recordings.removeLast()
            try? FileManager.default.removeItem(atPath: dropped.path)
        }
        persist()
    }

    /// Drop entries whose file no longer exists (reboot, tmp_cleaner, user).
    func validate() {
        let existing = recordings.filter { FileManager.default.fileExists(atPath: $0.path) }
        if existing.count != recordings.count {
            recordings = existing
            persist()
        }
    }

    func clearAll() {
        for recording in recordings {
            try? FileManager.default.removeItem(atPath: recording.path)
        }
        recordings = []
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.recentRecordings),
              let list = try? JSONDecoder().decode([Recording].self, from: data)
        else { return }
        recordings = list
    }

    private func persist() {
        let data = (try? JSONEncoder().encode(recordings)) ?? Data()
        UserDefaults.standard.set(data, forKey: DefaultsKey.recentRecordings)
    }
}
