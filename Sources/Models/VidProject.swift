import Foundation

/// The serializable state of a ClipStitcher project: the ordered clips, which clip
/// is the target, and the output settings. Persisted as JSON in the `.clipstitcher`
/// document.
struct VidProject: Codable, Equatable {
    var clips: [Clip] = []
    var targetClipID: Clip.ID? = nil
    var output: OutputSettings = OutputSettings()
    /// The output track heard in the Preview's audio picker (issue #8). nil on saves
    /// made before preview audio — then the default, output track 1.
    var monitoredOutputTrack: Int? = nil

    /// The clip whose properties define the output spec, if one is set and still present.
    var targetClip: Clip? {
        targetClipID.flatMap { id in clips.first { $0.id == id } }
    }
}
