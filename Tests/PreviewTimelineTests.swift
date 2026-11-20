import Testing
import Foundation
@testable import ClipStitcher

struct PreviewTimelineTests {
    private let idA = UUID()
    private let idB = UUID()

    private func pts(_ count: Int, fps: Double, start: Double = 0) -> [Double] {
        (0..<count).map { start + Double($0) / fps }
    }

    @Test func matchingClipsConcatenateTheirKeptRanges() {
        let timeline = PreviewTimeline.build(clips: [
            .init(clipID: idA, pts: pts(100, fps: 25), inPoint: nil, outPoint: 24,
                  duration: 4, conformed: false),
            .init(clipID: idB, pts: pts(100, fps: 25), inPoint: 5, outPoint: 14,
                  duration: 4, conformed: false),
        ], targetFrameRate: "25/1")

        #expect(timeline.totalFrames == 35)
        #expect(timeline.joinFrames == [25])

        let (i, local) = timeline.locate(30)!
        #expect(i == 1 && local == 5)
        let segment = timeline.segments[1]
        #expect(timeline.sourceFrame(in: segment, local: local, pts: pts(100, fps: 25)) == 10)
    }

    @Test func locateClampsOutOfRangeFramesToTheEnds() {
        let timeline = PreviewTimeline.build(clips: [
            .init(clipID: idA, pts: pts(10, fps: 25), inPoint: nil, outPoint: nil,
                  duration: nil, conformed: false),
        ], targetFrameRate: "25/1")

        #expect(timeline.locate(-5)! == (0, 0))
        #expect(timeline.locate(999)! == (0, 9))
    }

    @Test func clipsWithoutFramesAreSkipped() {
        let timeline = PreviewTimeline.build(clips: [
            .init(clipID: idA, pts: [], inPoint: nil, outPoint: nil,
                  duration: nil, conformed: false),
            .init(clipID: idB, pts: pts(10, fps: 25), inPoint: nil, outPoint: nil,
                  duration: nil, conformed: false),
        ], targetFrameRate: "25/1")

        #expect(timeline.segments.count == 1)
        #expect(timeline.segments[0].clipID == idB)
        #expect(timeline.joinFrames.isEmpty)
    }

    @Test func conformedClipIsRetimedToTheTargetRate() {
        let source = pts(100, fps: 50)
        let timeline = PreviewTimeline.build(clips: [
            .init(clipID: idA, pts: source, inPoint: 10, outPoint: 60,
                  duration: 2, conformed: true),
        ], targetFrameRate: "25/1")

        #expect(timeline.totalFrames == 25)
        let segment = timeline.segments[0]
        #expect(timeline.sourceFrame(in: segment, local: 0, pts: source) == 10)
        #expect(timeline.sourceFrame(in: segment, local: 1, pts: source) == 12)
        #expect(timeline.sourceFrame(in: segment, local: 24, pts: source) == 58)
    }

    @Test func openInPointWindowStartsAtZeroLikeTheExport() {
        let source = pts(100, fps: 25, start: 0.24)
        let timeline = PreviewTimeline.build(clips: [
            .init(clipID: idA, pts: source, inPoint: nil, outPoint: 49,
                  duration: 4.24, conformed: true),
        ], targetFrameRate: "25/1")

        #expect(timeline.totalFrames == 55)
        let segment = timeline.segments[0]
        #expect(timeline.sourceFrame(in: segment, local: 0, pts: source) == 0)
    }

    @Test func openOutPointWindowEndsAtTheProbedDuration() {
        let source = pts(200, fps: 50)
        let timeline = PreviewTimeline.build(clips: [
            .init(clipID: idA, pts: source, inPoint: nil, outPoint: nil,
                  duration: 4.0, conformed: true),
        ], targetFrameRate: "25/1")

        #expect(timeline.totalFrames == 100)
        let segment = timeline.segments[0]
        #expect(timeline.sourceFrame(in: segment, local: 99, pts: source) == 198)
    }

    @Test func conformedMappingClampsToTheKeptRange() {
        let source = pts(100, fps: 50)
        let timeline = PreviewTimeline.build(clips: [
            .init(clipID: idA, pts: source, inPoint: 10, outPoint: 20,
                  duration: 2, conformed: true),
        ], targetFrameRate: "25/1")

        let segment = timeline.segments[0]
        for local in 0..<segment.outputCount {
            let frame = timeline.sourceFrame(in: segment, local: local, pts: source)
            #expect(frame >= 10 && frame <= 20)
        }
    }

    private func flags(_ count: Int, keyframes: [Int]) -> [Bool] {
        (0..<count).map { keyframes.contains($0) }
    }

    @Test func anchorsMapKeptKeyframesToOutputFramesAndIncludeJoins() {
        let a = FrameIndex(pts: pts(100, fps: 25), keyframeFlags: flags(100, keyframes: [0, 12, 40]))
        let b = FrameIndex(pts: pts(100, fps: 25), keyframeFlags: flags(100, keyframes: [5, 10]))
        let timeline = PreviewTimeline.build(clips: [
            .init(clipID: idA, pts: a.pts, inPoint: nil, outPoint: 24, duration: 4, conformed: false),
            .init(clipID: idB, pts: b.pts, inPoint: 5, outPoint: 14, duration: 4, conformed: false),
        ], targetFrameRate: "25/1")
        let indexes = [idA: a, idB: b]

        let anchors = timeline.keyframeAnchorFrames { indexes[$0] }
        #expect(anchors == [0, 12, 25, 30])
    }

    @Test func aKeyframelessKeptRangeStillAnchorsItsJoin() {
        let a = FrameIndex(pts: pts(50, fps: 25), keyframeFlags: flags(50, keyframes: [0]))
        let b = FrameIndex(pts: pts(50, fps: 25), keyframeFlags: flags(50, keyframes: [0]))
        let timeline = PreviewTimeline.build(clips: [
            .init(clipID: idA, pts: a.pts, inPoint: nil, outPoint: 9, duration: 2, conformed: false),
            .init(clipID: idB, pts: b.pts, inPoint: 20, outPoint: 29, duration: 2, conformed: false),
        ], targetFrameRate: "25/1")
        let indexes = [idA: a, idB: b]

        let anchors = timeline.keyframeAnchorFrames { indexes[$0] }
        #expect(anchors == [0, 10])
    }

    @Test func conformedKeyframesMapThroughTimeToOutputFrames() {
        let source = pts(100, fps: 50)
        let index = FrameIndex(pts: source, keyframeFlags: flags(100, keyframes: [30]))
        let timeline = PreviewTimeline.build(clips: [
            .init(clipID: idA, pts: source, inPoint: 10, outPoint: 60, duration: 2, conformed: true),
        ], targetFrameRate: "25/1")
        let segment = timeline.segments[0]

        #expect(timeline.outputFrame(forSource: 30, in: segment, pts: source) == 10)
        #expect(timeline.sourceFrame(in: segment, local: 10, pts: source) == 30)
        let anchors = timeline.keyframeAnchorFrames { _ in index }
        #expect(anchors == [0, 10])
    }

    @Test func outputFrameClampsIntoTheSegment() {
        let source = pts(100, fps: 25)
        let timeline = PreviewTimeline.build(clips: [
            .init(clipID: idA, pts: source, inPoint: 10, outPoint: 19, duration: 4, conformed: false),
        ], targetFrameRate: "25/1")
        let segment = timeline.segments[0]

        #expect(timeline.outputFrame(forSource: 5, in: segment, pts: source) == 0)
        #expect(timeline.outputFrame(forSource: 50, in: segment, pts: source) == 9)
    }
}
