import Foundation

enum FFError: LocalizedError {
    case toolNotFound(String)
    case probeFailed(String)
    case indexFailed(String)

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let name):
            return "Could not find \(name). It will be bundled with the app; during development install it (e.g. `brew install ffmpeg`)."
        case .probeFailed(let detail):
            return "Could not read media properties.\n\(detail)"
        case .indexFailed(let detail):
            return "Could not index frames.\n\(detail)"
        }
    }
}

/// Locates the ffprobe / ffmpeg binaries.
///
/// For a release build these are bundled inside the app (ADR-0002). During
/// development we fall back to a Homebrew/system install so the app is runnable
/// before the bundling step is set up.
enum FFTools {
    static func ffprobeURL() throws -> URL { try locate("ffprobe") }
    static func ffmpegURL() throws -> URL { try locate("ffmpeg") }

    private static func locate(_ name: String) throws -> URL {
        if let bundled = Bundle.main.url(forResource: name, withExtension: nil) {
            return bundled
        }
        for dir in ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"] {
            let candidate = URL(fileURLWithPath: dir + name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw FFError.toolNotFound(name)
    }
}
