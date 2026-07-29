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

    /// The file currently being written (recording in progress, or a GIF
    /// conversion target). Excluded from the older-files scan so an
    /// unfinalized file can never be opened or cleared from the menu.
    var activeRecordingURL: URL?

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
        // Pinned locale: the user's locale may render format patterns with
        // non-Latin digits (Arabic-Indic, Devanagari, …) — file names should
        // be ASCII everywhere.
        for formatter in [date, time] {
            formatter.locale = Locale(identifier: "en_US_POSIX")
        }
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
        // Second recording within the same second: suffix instead of letting
        // the engine overwrite the first.
        var url = directory.appendingPathComponent("\(name).\(fileExtension)")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(name)-\(counter).\(fileExtension)")
            counter += 1
        }
        return url
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
            // Entry only — the file stays on disk and moves to the
            // "Older Recordings" submenu. Deleting here would silently
            // destroy user files in permanent storage locations.
            recordings.removeLast()
        }
        persist()
    }

    struct OlderFile {
        var url: URL
        var bytes: Int64
        var date: Date
    }

    /// Recordings on disk beyond the recents list — entries that scrolled out,
    /// or files left by an earlier run: every mp4/gif in the storage
    /// directory, newest first. The recents themselves and the file currently
    /// being written are excluded. Paths are compared symlink-resolved,
    /// because /tmp is a symlink to /private/tmp and directory enumeration
    /// returns the resolved form.
    func olderRecordings() -> [OlderFile] {
        var known = Set(recordings.map { Self.resolvedPath($0.path) })
        if let active = activeRecordingURL {
            known.insert(Self.resolvedPath(active.path))
        }
        let extensions: Set<String> = ["mp4", "gif"]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: Self.directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { return [] }
        return entries
            .filter {
                extensions.contains($0.pathExtension.lowercased())
                    && !known.contains(Self.resolvedPath($0.path))
            }
            .map { url in
                let values = try? url.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey])
                return OlderFile(url: url,
                                 bytes: Int64(values?.fileSize ?? 0),
                                 date: values?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.date > $1.date }
    }

    private static func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Drop entries whose file no longer exists (reboot, tmp_cleaner, user).
    func validate() {
        let existing = recordings.filter { FileManager.default.fileExists(atPath: $0.path) }
        if existing.count != recordings.count {
            recordings = existing
            persist()
        }
    }

    /// Removes everything screc lists: the recents plus the older files in
    /// the storage directory. Permanent locations go through the Trash so a
    /// mistaken click stays recoverable; /tmp is deleted outright — those
    /// files are throwaway by design.
    func clearAll(toTrash: Bool) {
        remove(recordings.map(\.url) + olderRecordings().map(\.url), toTrash: toTrash)
        recordings = []
        persist()
    }

    /// Removes only the overhang — the older files beyond the recents list.
    /// The recents themselves stay untouched.
    func clearOlder(toTrash: Bool) {
        remove(olderRecordings().map(\.url), toTrash: toTrash)
    }

    private func remove(_ urls: [URL], toTrash: Bool) {
        for url in urls {
            do {
                if toTrash {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } else {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                Log.store.error("could not remove \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
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
