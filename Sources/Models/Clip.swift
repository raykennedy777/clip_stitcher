import Foundation

/// One imported source file plus its selected in/out range and probed properties.
/// Occupies one row in the timeline.
struct Clip: Codable, Identifiable, Equatable {
    var id: UUID = UUID()

    /// Bookmark to the source file on disk. Resolved to a URL at runtime; the media
    /// itself is never stored in the project.
    var bookmark: Data

    var displayName: String

    // Probed properties (filled asynchronously after import).
    var video: VideoProperties? = nil
    var audio: AudioProperties? = nil
    var duration: Double? = nil
    var frameCount: Int? = nil

    // Selection range, in source frame numbers. nil means the clip boundary
    // (0 for in, last frame for out). Set later in the cut-editor.
    var inPoint: Int? = nil
    var outPoint: Int? = nil
}
