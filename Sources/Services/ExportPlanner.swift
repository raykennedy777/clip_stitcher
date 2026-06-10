import Foundation

/// The pure planning behind the document's export entry point: per clip, the
/// smart-render-vs-conform verdict (ADR-0005 / ADR-0011), the boundary re-encode
/// segment plan (ADR-0009), the kept window every audio leg is forced to (ADR-0014),
/// and the assembled `ExportItem` the engine consumes. Clips, the target clip, frame
/// indexes, and container start times go in; export items come out — no file IO, so
/// the verdict matrix is unit-testable without constructing a document.
enum ExportPlanner {
    /// Everything the planner needs to know about one clip, gathered by the caller
    /// (the file IO — URL resolution, frame indexing, the start-time probe, and the
    /// audio source resolution — is done by then).
    struct ClipInput {
        var clip: Clip
        var url: URL
        var index: FrameIndex
        var containerStart: Double
        var audioSources: [ExportEngine.AudioSource?]
    }

    /// How one clip's video reaches the output (ADR-0011) — exactly one of the two,
    /// by construction. A clip is *either* smart-rendered (the keyframe-bounded middle
    /// stream-copied, the partial-GOP edges re-encoded with source-matched args —
    /// ADR-0009) *or* conformed (its whole kept range re-encoded to the target spec);
    /// the old both/neither states a caller could assemble are unrepresentable here.
    enum VideoTreatment: Equatable {
        case smartRender(segments: [PlannedSegment], encoder: [String])
        case conform(ConformEngine.VideoConform)
    }

    /// One clip's video treatment. A clip that doesn't match the target is conformed:
    /// a full re-encode of its kept range to the target spec (ADR-0011). A matching
    /// clip — or any clip when there is no target video spec or no probed clip video
    /// to compare — is smart-rendered. Audio never enters the verdict — every leg is
    /// conformed to its output track's format inside the rebuild chain (ADR-0014).
    /// On the smart-render path, throws `ExportError.invalidPlan` when the kept range
    /// collapses to nothing.
    static func videoTreatment(for clip: Clip, target: Clip?, index: FrameIndex) throws -> VideoTreatment {
        if let target, let tv = target.video, let cv = clip.video,
           !MatchEvaluator.matches(clip, target: target) {
            return .conform(ConformEngine.VideoConform(sourceVideo: cv, targetVideo: tv))
        }
        let leadingCounts = CopySafeBoundaryDetector.leadingPictureCounts(
            keyframeFlags: index.keyframeFlags, dts: index.dts)
        let segments = BoundaryReencodePlanner.plan(
            leadingCounts: leadingCounts, frameCount: index.count,
            inFrame: clip.inPoint, outFrame: clip.outPoint)
        guard !segments.isEmpty else { throw ExportError.invalidPlan }
        // Re-encode args matched to the source so the edges concat cleanly with the
        // copied middle (ADR-0009).
        let encoder = BoundaryReencodeEngine.reencodeVideoArgs(
            codec: clip.video?.codec,
            profile: clip.video?.profile,
            pixelFormat: clip.video?.pixelFormat,
            fieldOrder: clip.video?.fieldOrder)
        return .smartRender(segments: segments, encoder: encoder)
    }

    /// The target the verdict consults. Cut-only severs it (ADR-0018): in separate mode
    /// with the cut-only rendering choice every clip smart-renders against itself —
    /// `videoTreatment` with no target never constructs `.conform`, and the boundary
    /// re-encode args already derive from the clip's own probed properties (ADR-0009).
    /// Every other mode×rendering combination consults the project's target unchanged.
    static func effectiveTarget(_ target: Clip?, settings: OutputSettings) -> Clip? {
        settings.mode == .separate && settings.rendering == .cutOnly ? nil : target
    }

    /// Plans one clip's export item: the video treatment plus the kept range as a seek
    /// window. A `nil` in/out point means that end is the clip boundary (no cut there),
    /// so audio — and a conformed clip's video — runs to the file's start/end too. The
    /// window subtracts the container's start_time (issue #3: input `-ss` is measured
    /// from it, not absolute pts — passing pts cut every leg 0.24 s late on the MPEG-PS
    /// clip), and its duration is the kept *video* span every audio leg is forced to,
    /// so the output tracks stay sample-aligned at joins (ADR-0014).
    static func planItem(for input: ClipInput, target: Clip?,
                         settings: OutputSettings = OutputSettings()) throws -> ExportItem {
        let target = effectiveTarget(target, settings: settings)
        let clip = input.clip
        let index = input.index
        let window = ExportEngine.keptWindow(
            inPts: clip.inPoint.map { index.pts[$0] },
            outPts: clip.outPoint.map { index.pts[$0] },
            firstPts: index.pts.first, lastPts: index.pts.last,
            frameDuration: frameDuration(clip.video?.frameRate),
            containerStart: input.containerStart)
        switch try videoTreatment(for: clip, target: target, index: index) {
        case .conform(let conform):
            return ExportItem(source: input.url, displayName: clip.displayName,
                              codec: conform.targetVideo.codec,
                              audioStart: window.start, audioEnd: window.end,
                              audioSources: input.audioSources, audioDuration: window.duration,
                              conform: conform)
        case .smartRender(let segments, let encoder):
            return ExportItem(source: input.url, displayName: clip.displayName,
                              codec: clip.video?.codec,
                              segments: segments, index: index, encoder: encoder,
                              audioStart: window.start, audioEnd: window.end,
                              audioSources: input.audioSources, audioDuration: window.duration)
        }
    }

    /// One frame's duration in seconds from an ffprobe rational rate ("25/1" → 0.04);
    /// nil when the rate is missing or malformed.
    static func frameDuration(_ frameRate: String?) -> Double? {
        let parts = (frameRate ?? "").split(separator: "/")
        guard parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]),
              num > 0, den > 0 else { return nil }
        return den / num
    }
}
