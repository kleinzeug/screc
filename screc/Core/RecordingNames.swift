import Foundation

/// File-name construction, extracted for testability (compiled into both the
/// app and the hermetic unit-test bundle).
enum RecordingNames {
    /// Expands `{date}`/`{time}` tokens and sanitizes path-hostile characters.
    /// Locale is pinned: the user's locale may render format patterns with
    /// non-Latin digits (Arabic-Indic, Devanagari, …) — file names should be
    /// ASCII everywhere. Falls back to `screc-<date>-<time>` when the pattern
    /// collapses to nothing.
    static func make(pattern: String, now: Date, timeZone: TimeZone = .current) -> String {
        let date = DateFormatter()
        date.dateFormat = "yyyyMMdd"
        let time = DateFormatter()
        time.dateFormat = "HHmmss"
        for formatter in [date, time] {
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
        }
        let name = pattern
            .replacingOccurrences(of: "{date}", with: date.string(from: now))
            .replacingOccurrences(of: "{time}", with: time.string(from: now))
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            return "screc-\(date.string(from: now))-\(time.string(from: now))"
        }
        return name
    }
}
