import Foundation

/// The answer to `clipstitch --plan` (issue #115): everything the planner already knows
/// about a job before its first encoder starts, as one JSON document.
///
/// An agent driving the CLI used to learn what a job would do only by running it — nine
/// renders at a quarter of an hour each to discover one pixel-aspect-ratio mismatch. Every
/// number here comes out of `StitchPipeline.Prepared`, which costs the import-time scans
/// every run pays anyway; nothing in `make` spawns a process, so the query is always the
/// cheap half of the job.
///
/// The shape is a **contract** (`docs/stitch-job.md`, "Plan query"), versioned separately
/// from the Stitch Job's own version. An optional field is always written as `null`, never
/// omitted, so a reader can index it without checking for the key first — which is why the
/// nullable structs encode themselves instead of taking the synthesized `encodeIfPresent`.
struct PlanReport: Codable, Equatable {
    /// Plan-report contract version. Bumped when a field changes meaning or leaves.
    static let contractVersion = 1

    var version: Int = PlanReport.contractVersion
    var output: Output
    /// The target clip's index in `clips` — the clip whose spec the others conform to.
    var target: Int
    var clips: [ClipPlan]
    /// The job's output frames by how each one is produced. The three counts sum to the
    /// clips' `expectedFrames`.
    var totals: Totals
    var audio: Audio
    /// The same notices the export prints to stderr, in the same order.
    var warnings: [String]

    // MARK: - Totals

    /// Where a job's output frames come from — the split that sets a render's wall time,
    /// because only the two encoded kinds run an encoder. Counted in output frames, the
    /// unit of `ClipPlan.expectedFrames`: a repaired segment counts its slot budget, and a
    /// field-coded source counts frames, not fields.
    struct Totals: Codable, Equatable {
        /// Frames stream-copied from a source.
        var copiedFrames: Int
        /// Frames a smart-rendered clip re-encodes at its boundaries, repairs included.
        var reEncodedFrames: Int
        /// Frames a conformed clip re-encodes to the target's spec.
        var conformedFrames: Int
    }

    // MARK: - Output

    struct Output: Codable, Equatable {
        var container: String
        var type: String
        /// The CRF conformed clips encode at, or `null` for the encoder's own default.
        var conformCrf: Int?

        enum CodingKeys: String, CodingKey { case container, type, conformCrf }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(container, forKey: .container)
            try c.encode(type, forKey: .type)
            try c.encode(conformCrf, forKey: .conformCrf)
        }
    }

    // MARK: - Clips

    /// How one clip's video reaches the output.
    enum Treatment: String, Codable {
        /// Stream-copied outside the boundary GOPs (ADR-0009).
        case smartRender
        /// Fully re-encoded to the target's spec because it doesn't match (ADR-0011).
        case conform
    }

    struct ClipPlan: Codable, Equatable {
        /// The clip's 0-based position in the job's `clips[]` — the number every warning,
        /// error and piece file name uses.
        var index: Int
        var name: String
        var path: String
        var treatment: Treatment
        /// The kept range the job asked for.
        var kept: Kept
        /// The copy/re-encode plan, or `null` on a conformed clip (which has no segments —
        /// the whole kept range is one re-encode).
        var segments: [Segment]?
        /// The copy boundaries around the clip's marks, or `null` on a conformed clip
        /// (where moving a mark changes nothing — the clip re-encodes whole).
        var copySafeKeyframes: CopySafeKeyframes?
        /// Why this clip is conformed — every strict-compare property it differs from the
        /// target on (`MatchEvaluator.videoDifferences`). `null` on a smart-rendered clip.
        var reason: [Difference]?
        /// How much of the kept range is stream-copied, 0…1, weighted by duration.
        var copiedFraction: Double
        /// How many video frames this clip contributes to the output.
        var expectedFrames: Int

        enum CodingKeys: String, CodingKey {
            case index, name, path, treatment, kept, segments, copySafeKeyframes
            case reason, copiedFraction, expectedFrames
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(index, forKey: .index)
            try c.encode(name, forKey: .name)
            try c.encode(path, forKey: .path)
            try c.encode(treatment, forKey: .treatment)
            try c.encode(kept, forKey: .kept)
            try c.encode(segments, forKey: .segments)
            try c.encode(copySafeKeyframes, forKey: .copySafeKeyframes)
            try c.encode(reason, forKey: .reason)
            try c.encode(copiedFraction, forKey: .copiedFraction)
            try c.encode(expectedFrames, forKey: .expectedFrames)
        }
    }

    /// A clip's kept range. `inFrame`/`outFrame` are the job's own coordinates — 0-based
    /// presentation frames, `outFrame` **inclusive** — so a caller can write them straight
    /// back into the job. `frames` and `seconds` measure that range.
    struct Kept: Codable, Equatable {
        var inFrame: Int
        var outFrame: Int
        var frames: Int
        var seconds: Double
    }

    struct Segment: Codable, Equatable {
        enum Kind: String, Codable { case copy, reEncode }
        var kind: Kind
        /// Half-open `[lowerBound, upperBound)` in presentation frames.
        var frames: [Int]
        var seconds: Double
        /// Why this piece is re-encoded. `null` on a copy segment, which needs none.
        var reason: String?

        enum CodingKeys: String, CodingKey { case kind, frames, seconds, reason }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(kind, forKey: .kind)
            try c.encode(frames, forKey: .frames)
            try c.encode(seconds, forKey: .seconds)
            try c.encode(reason, forKey: .reason)
        }
    }

    /// The copy-safe keyframes bracketing a clip's two marks — where an agent moves a mark
    /// to trade frame accuracy for a shorter re-encode. `null` on a side with no such
    /// keyframe. The out pair brackets the kept range's **exclusive** end (`outFrame + 1`),
    /// which is what a copy segment's `frames[1]` is compared against; so an out point of
    /// `afterOut - 1` ends the clip on a pure copy.
    ///
    /// Conservative on the out side by design: these are copy-*start*-safe keyframes
    /// (`CopySafeBoundaryDetector.copySafeFlags`), and the planner can also end a copy just
    /// before an open keyframe (#16). A mark moved here is always copyable; a mark the
    /// planner also copies may sit closer.
    struct CopySafeKeyframes: Codable, Equatable {
        var beforeIn: Int?
        var afterIn: Int?
        var beforeOut: Int?
        var afterOut: Int?

        enum CodingKeys: String, CodingKey { case beforeIn, afterIn, beforeOut, afterOut }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(beforeIn, forKey: .beforeIn)
            try c.encode(afterIn, forKey: .afterIn)
            try c.encode(beforeOut, forKey: .beforeOut)
            try c.encode(afterOut, forKey: .afterOut)
        }
    }

    /// One property a conformed clip differs from the target on, named and formatted
    /// exactly as the app's inspector shows it.
    struct Difference: Codable, Equatable {
        var property: String
        var clip: String
        var target: String
    }

    // MARK: - Audio

    /// What the rebuilt audio will be, beside what the sources carry — the pair that makes
    /// a rate drop visible before the render rather than after it.
    struct Audio: Codable, Equatable {
        var codec: Codec
        var bitrate: Bitrate
        /// How many audio tracks the output carries.
        var tracks: Int

        /// Per output track the target clip's source codec (`null` for a track the target
        /// doesn't feed), and the one codec every track encodes to.
        struct Codec: Codable, Equatable {
            var `in`: [String?]
            var out: String
            /// True when the target's own codec was declined for AAC (ADR-0010).
            var fellBack: Bool
        }

        /// Rates as ffmpeg spells them, rounded to the nearest kbit — e.g. `"384k"`.
        /// `null` for a track whose container reports no rate, or no source.
        struct Bitrate: Codable, Equatable {
            var `in`: [String?]
            var out: String
        }
    }

    // MARK: - Derivation

    /// Builds the report from a prepared job. Pure: no file IO, no process, no ffmpeg — the
    /// probe and index scan inside `StitchPipeline.prepare` are the only tool runs a plan
    /// query makes.
    static func make(prepared: StitchPipeline.Prepared) -> PlanReport {
        let settings = prepared.settings
        let target = prepared.target
        let clips = prepared.items.indices.map { i in
            clipPlan(at: i, prepared: prepared)
        }
        // A video-only output writes no audio at all (`ExportEngine`'s `wantsAudio`), so the
        // report carries no tracks for it — a resolved track list an agent could read as a
        // promise of audio in the file would be a lie.
        let sourceTracks = target.effectiveAudioTracks
        let outputTracks = settings.type == .videoOnly ? 0 : prepared.tracks.count
        let trackProperties = (0..<outputTracks).map { t -> AudioProperties? in
            t < sourceTracks.count ? sourceTracks[t] : nil
        }
        let audio = Audio(
            codec: Audio.Codec(in: trackProperties.map { $0?.codec },
                               out: prepared.audio.codec,
                               fellBack: prepared.audio.fellBack),
            bitrate: Audio.Bitrate(in: trackProperties.map { $0?.bitrate.map(bitrateLabel) },
                                   out: ExportEngine.audioBitrate),
            tracks: outputTracks)
        return PlanReport(
            output: Output(container: settings.container.rawValue,
                           type: settings.type.rawValue,
                           conformCrf: settings.conformCrf),
            target: prepared.targetIndex,
            clips: clips,
            totals: totals(prepared: prepared),
            audio: audio,
            warnings: prepared.warnings)
    }

    private static func clipPlan(at i: Int, prepared: StitchPipeline.Prepared) -> ClipPlan {
        let item = prepared.items[i]
        let clip = prepared.clips[i]
        let facts = prepared.facts(forClip: i)
        let index = facts.index
        let inFrame = clip.inPoint ?? 0
        let endFrame = clip.outPoint.map { $0 + 1 } ?? index.count
        let kept = inFrame..<max(inFrame, endFrame)
        let conformed = item.conform != nil

        let copySafe = conformed ? [] : CopySafeBoundaryDetector.copySafeFlags(
            keyframeFlags: index.keyframeFlags, dts: index.dts)
        let segments = conformed ? nil : item.segments.map {
            segment($0, kept: kept, copySafe: copySafe, index: index)
        }
        // A conformed clip re-encodes its whole kept range; a smart-rendered one splits the
        // way the Output view's share does — the same function, never a second formula.
        let share = conformed
            ? ExportPlanner.CopyShare(copiedSeconds: 0,
                                      totalSeconds: ExportPlanner.duration(of: kept, index: index))
            : ExportPlanner.copyShare(segments: item.segments, index: index)
        let differences = item.conform.map { conform in
            MatchEvaluator.videoDifferences(conform.sourceVideo, conform.targetVideo)
                .map { Difference(property: $0.label, clip: $0.clipValue, target: $0.targetValue) }
        }
        return ClipPlan(
            index: i,
            name: clip.displayName,
            path: facts.url.path,
            treatment: conformed ? .conform : .smartRender,
            kept: Kept(inFrame: inFrame, outFrame: max(inFrame, endFrame - 1),
                       frames: kept.count,
                       seconds: rounded(ExportPlanner.duration(of: kept, index: index))),
            segments: segments,
            copySafeKeyframes: conformed ? nil
                : CopySafeKeyframes(beforeIn: nearestCopySafe(copySafe, from: inFrame, forward: false),
                                    afterIn: nearestCopySafe(copySafe, from: inFrame, forward: true),
                                    beforeOut: nearestCopySafe(copySafe, from: endFrame, forward: false),
                                    afterOut: nearestCopySafe(copySafe, from: endFrame, forward: true)),
            reason: differences,
            copiedFraction: rounded(share.copiedFraction, places: 4),
            expectedFrames: expectedFrames(item: item, kept: kept, index: index))
    }

    private static func segment(_ planned: PlannedSegment, kept: Range<Int>,
                                copySafe: [Bool], index: FrameIndex) -> Segment {
        Segment(kind: planned.kind == .copy ? .copy : .reEncode,
                frames: [planned.range.lowerBound, planned.range.upperBound],
                seconds: rounded(ExportPlanner.duration(of: planned.range, index: index)),
                reason: planned.kind == .copy ? nil
                    : reEncodeReason(planned, kept: kept, copySafe: copySafe))
    }

    /// Why a re-encode segment exists. `PlannedSegment` records no reason — it is a plan,
    /// not an explanation — so this reads it back off the segment's position in the kept
    /// range, the same three causes the planner has: a mark that isn't a copy boundary at
    /// either end (ADR-0009), or damage to repair (issue #47). More than one can hold at
    /// once — a one-segment plan meets both mark conditions — so every cause that applies
    /// is named.
    private static func reEncodeReason(_ planned: PlannedSegment, kept: Range<Int>,
                                       copySafe: [Bool]) -> String {
        var causes: [String] = []
        if planned.range.lowerBound == kept.lowerBound {
            causes.append("in point is not a copy-safe keyframe; "
                + describe(nearestCopySafe(copySafe, from: kept.lowerBound, forward: true),
                           "nearest copy-safe keyframe at or after it"))
        }
        if planned.range.upperBound == kept.upperBound {
            causes.append("out point is not a copy-safe keyframe; "
                + describe(nearestCopySafe(copySafe, from: kept.upperBound, forward: false),
                           "nearest copy-safe keyframe at or before it"))
        }
        if !planned.damage.isEmpty {
            let zones = planned.damage
                .map { String(format: "%.2f–%.2fs", $0.start, $0.end) }
                .joined(separator: ", ")
            causes.append("repairs damage at \(zones)")
        }
        return causes.isEmpty ? "boundary GOP re-encode" : causes.joined(separator: "; ")
    }

    private static func describe(_ frame: Int?, _ label: String) -> String {
        frame.map { "\(label) is \($0)" } ?? "there is no \(label)"
    }

    /// The nearest copy-safe keyframe at or before / at or after `frame`, or nil when that
    /// side has none.
    static func nearestCopySafe(_ copySafe: [Bool], from frame: Int, forward: Bool) -> Int? {
        guard !copySafe.isEmpty else { return nil }
        if forward {
            guard frame < copySafe.count else { return nil }
            return (max(0, frame)..<copySafe.count).first { copySafe[$0] }
        }
        guard frame >= 0 else { return nil }
        return stride(from: min(frame, copySafe.count - 1), through: 0, by: -1).first { copySafe[$0] }
    }

    /// How many video frames a clip contributes to the output.
    ///
    /// A **conform** re-encodes its kept window to the *target's* frame rate, which is a
    /// strict-compare property — so an fps mismatch is one of the things that routes a clip
    /// here, and counting its source frames would be counting the rate the conform is about
    /// to convert away from. The count is the window's duration at the target rate, through
    /// `ConformEngine.expectedFrameCount`: the same arithmetic the export's own acceptance
    /// bar applies to the piece it produces, so report and verifier cannot disagree. The
    /// window is shortened by a truncated ending where there is one (issue #79).
    ///
    /// A **smart render** writes its segments' frames, which are the source's — nothing is
    /// rate-converted. A damage-repaired segment writes the slot budget its fps fill
    /// produces, not its index span (issue #47). A field-coded (PAFF) source indexes
    /// **fields**, two per displayed frame (ADR-0022), so its count is halved: `kept` and
    /// `segments` stay in the job's own field coordinates, the output carries frames. Only
    /// this branch halves — a conform's count is already in target frames, and the planner
    /// never routes a field-coded clip to conform.
    ///
    /// On an audio-only output the file has no video; the count still measures the kept
    /// video range, which is the span each audio leg is rebuilt over (ADR-0014).
    static func expectedFrames(item: ExportItem, kept: Range<Int>, index: FrameIndex) -> Int {
        let split = frameSplit(item: item, kept: kept, index: index)
        return split.copiedFrames + split.reEncodedFrames + split.conformedFrames
    }

    /// One clip's `expectedFrames`, split by how each frame is produced. The arithmetic
    /// is `expectedFrames`' own (see there), so the split always sums to it.
    static func frameSplit(item: ExportItem, kept: Range<Int>, index: FrameIndex) -> Totals {
        if let conform = item.conform {
            let window = conform.trimEnd.map { $0 - (item.audioStart ?? 0) }
                ?? item.audioDuration
                ?? ExportPlanner.duration(of: kept, index: index)
            let frames = ConformEngine.expectedFrameCount(
                windowDuration: window,
                targetFrameRate: conform.targetVideo.frameRate) ?? kept.count
            return Totals(copiedFrames: 0, reEncodedFrames: 0, conformedFrames: frames)
        }
        var copied = 0, reEncoded = 0
        for segment in item.segments {
            let frames: Int
            if !segment.damage.isEmpty, let rate = item.frameRate {
                frames = BoundaryReencodeEngine.repairedSegmentExpectation(
                    range: segment.range, index: index, zones: segment.damage,
                    containerStart: item.containerStart, frameRate: rate).frames
            } else {
                frames = segment.range.count
            }
            if segment.kind == .copy { copied += frames } else { reEncoded += frames }
        }
        guard item.fieldCoded else {
            return Totals(copiedFrames: copied, reEncodedFrames: reEncoded, conformedFrames: 0)
        }
        // Halve the clip's sum, not each part, so the split still sums to the count.
        let frames = (copied + reEncoded) / 2
        return Totals(copiedFrames: frames - reEncoded / 2, reEncodedFrames: reEncoded / 2,
                      conformedFrames: 0)
    }

    /// The job-wide split: every clip's `frameSplit`, summed.
    static func totals(prepared: StitchPipeline.Prepared) -> Totals {
        prepared.items.indices.reduce(Totals(copiedFrames: 0, reEncodedFrames: 0, conformedFrames: 0)) { sum, i in
            let clip = prepared.clips[i]
            let index = prepared.facts(forClip: i).index
            let inFrame = clip.inPoint ?? 0
            let endFrame = clip.outPoint.map { $0 + 1 } ?? index.count
            let split = frameSplit(item: prepared.items[i],
                                   kept: inFrame..<max(inFrame, endFrame), index: index)
            return Totals(copiedFrames: sum.copiedFrames + split.copiedFrames,
                          reEncodedFrames: sum.reEncodedFrames + split.reEncodedFrames,
                          conformedFrames: sum.conformedFrames + split.conformedFrames)
        }
    }

    /// A source rate as ffmpeg spells one, to the nearest kbit — `384000` becomes `"384k"`,
    /// the same shape as the fixed output rate it sits beside.
    static func bitrateLabel(_ bitsPerSecond: Int) -> String {
        "\(Int((Double(bitsPerSecond) / 1000).rounded()))k"
    }

    /// Rounds a measured second/fraction before encoding. Without it a plain sum of frame
    /// pts prints as `842.1600000000001`, which is noise in a contract and a flake in a
    /// test that compares two JSON documents.
    static func rounded(_ value: Double, places: Int = 3) -> Double {
        let scale = pow(10.0, Double(places))
        return (value * scale).rounded() / scale
    }

    /// The report as the CLI writes it: stable key order (so two runs of one job diff
    /// clean) and indented (so a human can read the answer without a formatter).
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }
}
