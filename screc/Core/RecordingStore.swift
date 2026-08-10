import Foundation
import Security

/// Recordings live in /tmp/screc by default: macOS wipes /private/tmp at boot
/// and a daily tmp_cleaner daemon removes stale files, so disk space frees
/// itself. The sandboxed (App Store) build cannot reach /tmp — it uses the
/// container's temporary directory instead and re-creates the boot-wipe
/// semantics itself by deleting recordings from before the current boot at
/// launch. The recents list is persisted in UserDefaults and validated
/// against disk, since the files can vanish underneath us by design.
@MainActor
final class RecordingStore {
    struct Recording: Codable, Equatable {
        var path: String
        var date: Date
        var bytes: Int64

        var url: URL { URL(fileURLWithPath: path) }
        var name: String { url.lastPathComponent }
    }

    /// True in the sandboxed (App Store) build, read from this binary's own
    /// signed entitlements.
    ///
    /// NOT from the environment: `APP_SANDBOX_CONTAINER_ID` is absent and
    /// `HOME` is un-redirected even in a genuinely sandboxed build (verified
    /// 2026-07-29), and guessing wrong here would point recordings at /tmp,
    /// which the sandbox refuses — every recording would fail.
    static let isSandboxed: Bool = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                  task, "com.apple.security.app-sandbox" as CFString, nil)
        else { return false }
        return (value as? NSNumber)?.boolValue ?? false
    }()

    /// Resolved from settings: the self-cleaning temp location, ~/Movies/screc
    /// (self-built only — the sandbox offers no blanket Movies access), or a
    /// custom folder (bookmark-backed under the sandbox).
    static var directory: URL {
        switch Prefs.storageChoice {
        case "movies" where !isSandboxed:
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Movies/screc", isDirectory: true)
        case "custom":
            if let custom = customDirectory() { return custom }
            return temporaryDirectory
        default:
            return temporaryDirectory
        }
    }

    private static var temporaryDirectory: URL {
        isSandboxed
            ? FileManager.default.temporaryDirectory
                .appendingPathComponent("screc", isDirectory: true)
            : URL(fileURLWithPath: "/tmp/screc", isDirectory: true)
    }

    // MARK: Custom folder (security-scoped under the sandbox)

    /// Resolved once per launch; the security scope stays open for the
    /// process lifetime (recordings can land there at any time).
    private static var resolvedCustomDirectory: URL??

    static func customDirectory() -> URL? {
        if let cached = resolvedCustomDirectory { return cached }
        let url = resolveCustomDirectory()
        resolvedCustomDirectory = url
        return url
    }

    private static func resolveCustomDirectory() -> URL? {
        if let data = UserDefaults.standard.data(forKey: DefaultsKey.customStorageBookmark) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data,
                                  options: [.withSecurityScope],
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &stale) {
                if stale, let fresh = try? url.bookmarkData(
                        options: [.withSecurityScope],
                        includingResourceValuesForKeys: nil, relativeTo: nil) {
                    UserDefaults.standard.set(fresh, forKey: DefaultsKey.customStorageBookmark)
                }
                if !url.startAccessingSecurityScopedResource() {
                    Log.store.notice("security scope not granted for \(url.path) — trying anyway")
                }
                return url
            }
            Log.store.error("custom-folder bookmark failed to resolve — falling back to the path")
        }
        let path = Prefs.customStoragePath
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Called by Settings when the user picks a folder: persist path (for
    /// display) + security-scoped bookmark (for access across relaunches in
    /// the sandbox — a bare path dies with the NSOpenPanel grant).
    static func rememberCustomFolder(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: DefaultsKey.customStoragePath)
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope],
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: DefaultsKey.customStorageBookmark)
        } catch {
            UserDefaults.standard.removeObject(forKey: DefaultsKey.customStorageBookmark)
            Log.store.error("could not create folder bookmark: \(error.localizedDescription)")
        }
        resolvedCustomDirectory = nil
    }

    private static let maxEntries = 10

    private(set) var recordings: [Recording] = []

    /// The file currently being written (recording in progress, or a GIF
    /// conversion target). Excluded from the older-files scan so an
    /// unfinalized file can never be opened or cleared from the menu.
    var activeRecordingURL: URL?

    init() {
        Log.store.notice("""
            storage: sandboxed=\(Self.isSandboxed, privacy: .public) \
            choice=\(Prefs.storageChoice, privacy: .public) \
            dir=\(Self.directory.path, privacy: .public)
            """)
        purgePreBootRecordings()
        load()
        validate()
    }

    /// Sandbox stand-in for /tmp's boot wipe: recordings in the container's
    /// temp location that predate the current boot are deleted at launch.
    private func purgePreBootRecordings() {
        guard Self.isSandboxed, Prefs.storageChoice == "tmp",
              let boot = Self.bootDate() else { return }
        let extensions: Set<String> = ["mp4", "gif"]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: Self.directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { return }
        for url in entries where extensions.contains(url.pathExtension.lowercased()) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modified < boot {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func bootDate() -> Date? {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0,
              bootTime.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(bootTime.tv_sec))
    }

    var totalBytes: Int64 {
        recordings.reduce(0) { $0 + $1.bytes }
    }

    func newOutputURL(fileExtension: String) -> URL {
        let directory = Self.directory
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        let name = RecordingNames.make(pattern: Prefs.fileNamePattern, now: Date())
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

    /// Deletes a single recording, whether it is in the recents list or among
    /// the older files. Same policy as Clear All: permanent storage goes
    /// through the Trash so a mis-click stays recoverable, /tmp is erased
    /// outright since those files are throwaway by design.
    func delete(_ url: URL) {
        remove([url], toTrash: Prefs.storageChoice != "tmp")
        let resolved = Self.resolvedPath(url.path)
        if let index = recordings.firstIndex(where: {
            Self.resolvedPath($0.path) == resolved
        }) {
            recordings.remove(at: index)
            persist()
        }
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
