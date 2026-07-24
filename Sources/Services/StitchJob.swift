import Foundation

/// The headless CLI's job description (issue #105): everything the GUI collects
/// interactively — the ordered clips, their in/out points, each clip's audio track
/// selection, which clip is the target, and the output settings — as one JSON file
/// referencing sources by **plain file path** (no security-scoped bookmarks; the CLI
/// runs unsandboxed). `docs/stitch-job.md` is the public, cross-repo contract this
/// type decodes; the shape deliberately mirrors the Codable project model
/// (`VidProject`/`Clip`/`OutputSettings`) so the two can't drift apart in meaning.
///
/// Decoding and validation are pure — no file IO — so the whole contract is
/// unit-testable from JSON literals. Checks that need the probed source (frame
/// ranges vs the real frame count, audio stream indices vs the real stream list)
/// live in `StitchPipeline`, which owns the IO.
struct StitchJob: Codable, Equatable {
    /// Contract version. The CLI refuses versions it doesn't know rather than
    /// half-reading a future job shape.
    static let supportedVersion = 1

    var version: Int
    var clips: [JobClip]
    var output: JobOutput? = nil

    /// One timeline entry. `inFrame`/`outFrame` are 0-based frame numbers in
    /// **presentation order** — exactly the GUI's `Clip.inPoint`/`outPoint` semantics
    /// (ADR-0006): `outFrame` is the last kept frame (inclusive), and an omitted end
    /// means the clip boundary. On a field-coded (PAFF) source the index counts
    /// *fields*, as everywhere else in the app.
    struct JobClip: Codable, Equatable {
        var path: String
        /// Display name for warnings/errors; the file name when omitted.
        var name: String? = nil
        var inFrame: Int? = nil
        var outFrame: Int? = nil
        /// Which of this file's own audio streams feed the output tracks, in output
        /// track order (0-based indices among the file's **audio** streams — `0:a:N`).
        /// Omitted means all of the clip's own audio streams in container order, the
        /// GUI default (ADR-0014). Different clips may select different streams —
        /// that is the point (each output track's leg is chosen per clip).
        var audioTracks: [Int]? = nil
        /// Marks the target clip — the clip whose properties define the output spec
        /// (ADR-0005): non-matching clips are conformed to it (ADR-0011). Exactly one
        /// entry must set this.
        var target: Bool? = nil
    }

    /// Output settings, all optional. `mode` is not part of the contract: the CLI
    /// always connects into the one output file it was given (`OutputMode.connect`);
    /// per-clip output splitting stays a GUI affordance.
    struct JobOutput: Codable, Equatable {
        /// "mkv" (default), "ts", or "mp4" — `Container`'s raw values.
        var container: String? = nil
        /// "videoAndAudio" (default), "videoOnly", or "audioOnly" — `OutputType`'s
        /// raw values.
        var type: String? = nil
        /// The CRF conformed (non-matching) clips encode at, 0–51. Omitted keeps the
        /// encoder default (libx264 23, libx265 28). This is how a fill clip's conform
        /// is pinned to the quality class of the footage around it; applies to
        /// x264/x265 conform encoders only — an MPEG-2 target ignores it.
        var conformCrf: Int? = nil
    }

    /// Decodes and structurally validates a job in one step — the only entry the CLI
    /// uses, so no path can act on a decoded-but-unvalidated job.
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

    /// The structural checks that need no probed source: version, at least one clip,
    /// exactly one target, sane frame ranges, non-negative audio stream indices, and
    /// known output enum strings. Everything else (ranges vs the real file) is the
    /// pipeline's post-probe validation.
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

    /// The index of the target clip. Force-unwrappable after `validate()`; optional so
    /// pre-validation callers can't trap.
    var targetIndex: Int? {
        clips.firstIndex { $0.target == true }
    }

    /// The job's output settings mapped onto the GUI model: mode is always `.connect`
    /// (the CLI writes the one file it was told to), and the container/type strings
    /// must be exact raw values — a typo'd "MKV" is refused, never silently defaulted.
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
            // Both conform encoders accept 0–51 (x264/x265's shared CRF scale).
            guard (0...51).contains(crf) else {
                throw StitchJobError.badConformCrf(crf)
            }
            settings.conformCrf = crf
        }
        return settings
    }

    /// A `JSONDecoder` failure as one legible line (path + reason) — the raw
    /// `DecodingError` description is a nested enum dump nobody can script against.
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
    /// The GUI-model clip this entry denotes once its source is probed: probed
    /// properties filled exactly as import fills them, the job's in/out as
    /// `inPoint`/`outPoint`, and the audio selection as own-stream slots at the
    /// Original mix (the CLI contract has no external audio files or channel mixes).
    /// The bookmark is empty — the pipeline resolves sources by path and never
    /// touches it. `fieldCoded`/`damageZones` are stamped by the pipeline afterward,
    /// once its index/detection pass has them.
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

/// Why a Stitch Job was refused — the CLI's "invalid job" failure class (exit code
/// 65, EX_DATAERR): the job file itself is wrong, or it doesn't fit the sources it
/// names. Distinct from probe/index failures (the source couldn't be *read* — exit
/// 66) and export failures (planning/producing the output failed — exit 70), so a
/// driving script can tell whose fault the failure is.
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
    /// A named source doesn't exist on disk. Job-class, not probe-class: the path is
    /// the job's claim, and it's checked before any tool runs.
    case missingSource(String)
    /// Post-probe: a frame number outruns the source's real frame count. The CLI
    /// refuses rather than adopting the GUI's reset-to-whole-clip reconciliation
    /// (issue #74) — a script asked for an exact range; silently exporting a
    /// different one would corrupt the caller's timeline math.
    case frameOutOfRange(clip: Int, frame: Int, frameCount: Int)
    /// Post-probe: a selected audio stream doesn't exist in the source. Refused for
    /// the same reason — the GUI's silence fallback (ADR-0014) exists for slots a
    /// *richer* clip created, not for an explicit selection that names a missing
    /// stream.
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
