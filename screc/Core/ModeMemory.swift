import AppKit

/// What each capture mode remembers between runs, so the primary click, the
/// hotkeys and the ⌥ menu entries can start immediately instead of asking
/// again. Kept separate per mode: switching to Full Screen must not forget
/// the last region.
enum ModeMemory {
    // MARK: Region

    struct Region: Codable {
        var display: UInt32
        var x: Double, y: Double, width: Double, height: Double

        /// Display-local, top-left origin — the `sourceRect` convention.
        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    static var region: Region? {
        get { decode(DefaultsKey.memoryRegion) }
        set { encode(newValue, DefaultsKey.memoryRegion) }
    }

    static func rememberRegion(display: CGDirectDisplayID, rect: CGRect) {
        region = Region(display: display, x: rect.minX, y: rect.minY,
                        width: rect.width, height: rect.height)
    }

    /// Only usable while that display still exists and can still hold the rect.
    static func usableRegion() -> (CGDirectDisplayID, CGRect)? {
        guard let region,
              let screen = NSScreen.screens.first(where: { $0.displayID == region.display })
        else { return nil }
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        let rect = region.rect
        guard rect.width >= 8, rect.height >= 8,
              bounds.insetBy(dx: -1, dy: -1).contains(rect)
        else { return nil }
        return (region.display, rect)
    }

    // MARK: Pinned window

    struct Pinned: Codable {
        var ownerName: String
        var title: String
        var x: Double, y: Double, width: Double, height: Double

        var normalizedRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    static var pinned: Pinned? {
        get { decode(DefaultsKey.memoryPinned) }
        set { encode(newValue, DefaultsKey.memoryPinned) }
    }

    static func rememberPinned(_ selection: PinnedSelection) {
        pinned = Pinned(ownerName: selection.ownerName, title: selection.title,
                        x: selection.normalizedRect.minX, y: selection.normalizedRect.minY,
                        width: selection.normalizedRect.width,
                        height: selection.normalizedRect.height)
    }

    /// Re-locates the remembered window if it is on screen right now.
    @MainActor
    static func usablePinned() -> PinnedSelection? {
        guard let pinned else { return nil }
        let identity = PinnedWindowTracker.Identity(ownerName: pinned.ownerName,
                                                   title: pinned.title)
        guard let found = PinnedWindowTracker.findWindow(matching: identity) else { return nil }
        return PinnedSelection(windowID: found.id,
                               ownerName: pinned.ownerName,
                               title: pinned.title,
                               frame: found.frame,
                               normalizedRect: pinned.normalizedRect)
    }

    // MARK: Display

    struct Display: Codable {
        var display: UInt32
        /// Signature of the screen arrangement when this display was chosen;
        /// if the layout changed, the choice is no longer trustworthy.
        var arrangement: String
    }

    static var display: Display? {
        get { decode(DefaultsKey.memoryDisplay) }
        set { encode(newValue, DefaultsKey.memoryDisplay) }
    }

    static func rememberDisplay(_ id: CGDirectDisplayID) {
        display = Display(display: id, arrangement: arrangementSignature())
    }

    static func usableDisplay() -> CGDirectDisplayID? {
        guard let display,
              display.arrangement == arrangementSignature(),
              NSScreen.screens.contains(where: { $0.displayID == display.display })
        else { return nil }
        return display.display
    }

    static func arrangementSignature() -> String {
        NSScreen.screens
            .map { screen in
                let f = screen.frame
                return "\(screen.displayID):\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))"
            }
            .sorted()
            .joined(separator: "|")
    }

    // MARK: - Storage

    private static func decode<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func encode<T: Encodable>(_ value: T?, _ key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }
}
