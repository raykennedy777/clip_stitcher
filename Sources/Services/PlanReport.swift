import Foundation

struct PlanReport: Codable, Equatable {
    static let contractVersion = 1

    var version: Int = PlanReport.contractVersion
    var output: Output
    var target: Int
    var clips: [ClipPlan]
    var totals: Totals
    var audio: Audio
    var warnings: [String]

    struct Totals: Codable, Equatable {
        var copiedFrames: Int
        var reEncodedFrames: Int
        var conformedFrames: Int
    }

    struct Output: Codable, Equatable {
        var container: String
        var type: String
        var conformCrf: Int?

        enum CodingKeys: String, CodingKey { case container, type, conformCrf }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(container, forKey: .container)
            try c.encode(type, forKey: .type)
            try c.encode(conformCrf, forKey: .conformCrf)
        }
    }

    enum Treatment: String, Codable {
        case smartRender
        case conform
    }

    struct ClipPlan: Codable, Equatable {
        var index: Int
        var name: String
        var path: String
        var treatment: Treatment
        var kept: Kept
        var segments: [Segment]?
        var copySafeKeyframes: CopySafeKeyframes?
        var reason: [Difference]?
        var copiedFraction: Double
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

    struct Kept: Codable, Equatable {
        var inFrame: Int
        var outFrame: Int
        var frames: Int
        var seconds: Double
    }

    struct Segment: Codable, Equatable {
        enum Kind: String, Codable { case copy, reEncode }
        var kind: Kind
        var frames: [Int]
        var seconds: Double
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

    struct Difference: Codable, Equatable {
        var property: String
        var clip: String
        var target: String
    }

    struct Audio: Codable, Equatable {
        var codec: Codec
        var bitrate: Bitrate
        var tracks: Int

        struct Codec: Codable, Equatable {
            var `in`: [String?]
            var out: String
            var fellBack: Bool
        }

        struct Bitrate: Codable, Equatable {
            var `in`: [String?]
            var out: String
        }
    }

    static func make(prepared: StitchPipeline.Prepared) -> PlanReport {
        let settings = prepared.settings
        let target = prepared.target
        let clips = prepared.items.indices.map { i in
            clipPlan(at: i, prepared: prepared)
        }
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
        let segments = conformed ? nil : item.segments.indices.map { s in
            segment(item.segments[s], kept: kept, copySafe: copySafe, index: index,
                    next: s + 1 < item.segments.count ? item.segments[s + 1] : nil)
        }
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
                                copySafe: [Bool], index: FrameIndex,
                                next: PlannedSegment?) -> Segment {
        Segment(kind: planned.kind == .copy ? .copy : .reEncode,
                frames: [planned.range.lowerBound, planned.range.upperBound],
                seconds: rounded(ExportPlanner.duration(of: planned.range, index: index)),
                reason: planned.kind == .copy ? nil
                    : reEncodeReason(planned, kept: kept, copySafe: copySafe, next: next))
    }

    private static func reEncodeReason(_ planned: PlannedSegment, kept: Range<Int>,
                                       copySafe: [Bool], next: PlannedSegment?) -> String {
        var causes: [String] = []
        if planned.range.lowerBound == kept.lowerBound, let next, next.kind == .copy,
           next.droppedLeadingPictures > 0 {
            causes.append("in point is not a keyframe; the copy starts at keyframe "
                + "\(next.range.lowerBound) and drops its "
                + StageClock.count(next.droppedLeadingPictures, "leading picture"))
        } else if planned.range.lowerBound == kept.lowerBound {
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

    static func nearestCopySafe(_ copySafe: [Bool], from frame: Int, forward: Bool) -> Int? {
        guard !copySafe.isEmpty else { return nil }
        if forward {
            guard frame < copySafe.count else { return nil }
            return (max(0, frame)..<copySafe.count).first { copySafe[$0] }
        }
        guard frame >= 0 else { return nil }
        return stride(from: min(frame, copySafe.count - 1), through: 0, by: -1).first { copySafe[$0] }
    }

    static func expectedFrames(item: ExportItem, kept: Range<Int>, index: FrameIndex) -> Int {
        let split = frameSplit(item: item, kept: kept, index: index)
        return split.copiedFrames + split.reEncodedFrames + split.conformedFrames
    }

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
        let frames = (copied + reEncoded) / 2
        return Totals(copiedFrames: frames - reEncoded / 2, reEncodedFrames: reEncoded / 2,
                      conformedFrames: 0)
    }

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

    static func bitrateLabel(_ bitsPerSecond: Int) -> String {
        "\(Int((Double(bitsPerSecond) / 1000).rounded()))k"
    }

    static func rounded(_ value: Double, places: Int = 3) -> Double {
        let scale = pow(10.0, Double(places))
        return (value * scale).rounded() / scale
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }
}
