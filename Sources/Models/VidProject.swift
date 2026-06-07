import Foundation

/// The serializable state of a VidConform project: the ordered clips, which clip
/// is the target, and the output settings. Persisted as JSON in the `.vidconform`
/// document.
struct VidProject: Codable, Equatable {
    var clips: [Clip] = []
    var targetClipID: Clip.ID? = nil
    var output: OutputSettings = OutputSettings()
}
