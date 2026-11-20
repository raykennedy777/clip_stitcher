import Foundation

struct StitchJob: Codable, Equatable {
    static let supportedVersion = 1

    var version: Int
    var clips: [JobClip]
    var output: JobOutput? = nil

    struct JobClip: Codable, Equatable {
        var path: String
        var name: String? = nil
        var inFrame: Int? = nil
        var outFrame: Int? = nil
        var audioTracks: [Int]? = nil
        var target: Bool? = nil
    }

    struct JobOutput: Codable, Equatable {
        var container: String? = nil
        var type: String? = nil
        var conformCrf: Int? = nil
    }

    static func parse(_ data: Data) throws -> StitchJob {
        let job: StitchJob
        do {
            job = try JSONDecoder().decode(StitchJob.self, from: data)
        } catch {
            throw StitchJobError.malformed(describeDecodingError(error))
        }
        try job.validate()
        return job
    }

    func validate() throws {
        guard version == Self.supportedVersion else {
            throw StitchJobError.unsupportedVersion(version)
        }
        guard !clips.isEmpty else { throw StitchJobError.noClips }
        let targets = clips.filter { $0.target == true }.count
        guard targets != 0 else { throw StitchJobError.noTarget }
        guard targets == 1 else { throw StitchJobError.multipleTargets }
        for (i, clip) in clips.enumerated() {
            guard !clip.path.isEmpty else {
                throw StitchJobError.emptyPath(clip: i)
            }
            if let inF = clip.inFrame, inF < 0 {
                throw StitchJobError.badFrameRange(clip: i, detail: "inFrame \(inF) is negative")
            }
            if let outF = clip.outFrame, outF < 0 {
                throw StitchJobError.badFrameRange(clip: i, detail: "outFrame \(outF) is negative")
            }
            if let inF = clip.inFrame, let outF = clip.outFrame, inF > outF {
                throw StitchJobError.badFrameRange(
                    clip: i, detail: "inFrame \(inF) is after outFrame \(outF)")
            }
            for t in clip.audioTracks ?? [] where t < 0 {
                throw StitchJobError.badAudioTrack(clip: i, index: t)
            }
        }
        _ = try outputSettings()
    }

    var targetIndex: Int? {
        clips.firstIndex { $0.target == true }
    }

    func outputSettings() throws -> OutputSettings {
        var settings = OutputSettings()
        settings.mode = .connect
        if let c = output?.container {
            guard let container = Container(rawValue: c) else {
                throw StitchJobError.unknownContainer(c)
            }
            settings.container = container
        }
        if let t = output?.type {
            guard let type = OutputType(rawValue: t) else {
                throw StitchJobError.unknownOutputType(t)
            }
            settings.type = type
        }
        if let crf = output?.conformCrf {
            guard (0...51).contains(crf) else {
                throw StitchJobError.badConformCrf(crf)
            }
            settings.conformCrf = crf
        }
        return settings
    }

    private static func describeDecodingError(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else {
            return error.localizedDescription
        }
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { key in
                key.intValue.map { "[\($0)]" } ?? key.stringValue
            }
            return keys.isEmpty ? "top level" : keys.joined(separator: ".")
        }
        switch decoding {
        case .keyNotFound(let key, let context):
            return "missing key “\(key.stringValue)” at \(path(context))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(context.debugDescription) at \(path(context))"
        @unknown default:
            return decoding.localizedDescription
        }
    }
}

extension StitchJob.JobClip {
    func modelClip(probe: MediaProbe.Result, frameCount: Int?) -> Clip {
        var clip = Clip(bookmark: Data(),
                        displayName: name ?? (path as NSString).lastPathComponent)
        clip.video = probe.video
        clip.audio = probe.audio
        clip.audioTracks = probe.audioTracks
        clip.duration = probe.duration
        clip.frameCount = frameCount
        clip.inPoint = inFrame
        clip.outPoint = outFrame
        clip.audioSelections = audioTracks.map { $0.map { AudioTrackSlot.stream($0) } }
        return clip
    }
}

enum StitchJobError: LocalizedError, Equatable {
    case malformed(String)
    case unsupportedVersion(Int)
    case noClips
    case noTarget
    case multipleTargets
    case emptyPath(clip: Int)
    case badFrameRange(clip: Int, detail: String)
    case badAudioTrack(clip: Int, index: Int)
    case unknownContainer(String)
    case unknownOutputType(String)
    case badConformCrf(Int)
    case missingSource(String)
    case frameOutOfRange(clip: Int, frame: Int, frameCount: Int)
    case audioTrackOutOfRange(clip: Int, index: Int, available: Int)

    var errorDescription: String? {
        switch self {
        case .malformed(let detail):
            return "The job file is not valid JSON for the Stitch Job schema: \(detail)"
        case .unsupportedVersion(let v):
            return "Unsupported Stitch Job version \(v) — this build understands version \(StitchJob.supportedVersion)."
        case .noClips:
            return "The job has no clips."
        case .noTarget:
            return "No clip is marked \"target\": true — exactly one must be."
        case .multipleTargets:
            return "More than one clip is marked \"target\": true — exactly one must be."
        case .emptyPath(let clip):
            return "Clip \(clip) has an empty path."
        case .badFrameRange(let clip, let detail):
            return "Clip \(clip) has an invalid frame range: \(detail)."
        case .badAudioTrack(let clip, let index):
            return "Clip \(clip) selects a negative audio stream index (\(index))."
        case .unknownContainer(let c):
            return "Unknown output container “\(c)” — use \"ts\", \"mkv\", or \"mp4\"."
        case .unknownOutputType(let t):
            return "Unknown output type “\(t)” — use \"videoAndAudio\", \"videoOnly\", or \"audioOnly\"."
        case .badConformCrf(let crf):
            return "conformCrf \(crf) is out of range — CRF is 0–51 (lower = higher quality)."
        case .missingSource(let path):
            return "Source file not found: \(path)"
        case .frameOutOfRange(let clip, let frame, let frameCount):
            return "Clip \(clip) references frame \(frame), but the source has only \(frameCount) frames (0–\(frameCount - 1))."
        case .audioTrackOutOfRange(let clip, let index, let available):
            return "Clip \(clip) selects audio stream \(index), but the source has only \(available) audio stream\(available == 1 ? "" : "s")."
        }
    }
}
