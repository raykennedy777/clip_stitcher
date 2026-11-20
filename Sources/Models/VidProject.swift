import Foundation

struct VidProject: Codable, Equatable {
    var clips: [Clip] = []
    var targetClipID: Clip.ID? = nil
    var output: OutputSettings = OutputSettings()
    var monitoredOutputTrack: Int? = nil

    var targetClip: Clip? {
        targetClipID.flatMap { id in clips.first { $0.id == id } }
    }
}
