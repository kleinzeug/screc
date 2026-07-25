import Foundation

enum ScrecError: LocalizedError {
    case noWindowToRecord
    case displayNotFound
    case nothingCaptured
    case writerFailed(String)
    case gifFailed(String)

    var errorDescription: String? {
        switch self {
        case .noWindowToRecord:
            "No recordable window found. Focus the window you want to capture and try again."
        case .displayNotFound:
            "That display is no longer available."
        case .nothingCaptured:
            "Recording stopped before any frames were captured — nothing was saved."
        case .writerFailed(let reason):
            "The video encoder failed: \(reason)"
        case .gifFailed(let reason):
            "GIF conversion failed: \(reason)"
        }
    }
}
