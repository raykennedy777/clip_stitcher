import Testing
import Foundation
@testable import VidConform

/// Pins the output-frame ↔ source-frame mapping of the preview's assembled timeline
/// (ADR-0012): matching clips pass through 1:1, conformed clips are re-timed to the
/// target rate with the same time window the export uses.
struct PreviewTimelineTests {
    private let idA = UUID()
    private let idB = UUID()

    /// pts for `count` frames at `fps`, starting at `start` (a non-zero start models a
    /// stream start_time, like the MPEG-2 footage's 0.24).
    private func pts(_ count: Int, fps: Double, start: Double = 0) -> [Double] {
        (0..<count).map { start + Double($0) / fps }
    }

    // MARK: Matching clips: 1:1 concatenation

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

    // MARK: Conformed clips: re-timed to the target rate

    @Test func conformedClipIsRetimedToTheTargetRate() {
        // A 50fps clip keeping frames 10–60 (1.0 s) in a 25fps project: the export's
        // conform produces 25 output frames, each mapping to every other source frame.
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
        // No in point → the export reads from the file start (no -ss), so the window
        // starts at 0 even when the stream's first pts is 0.24 (a start_time clip):
        // window = pts[out] - 0 = 2.2 s → 55 frames at 25fps.
        let source = pts(100, fps: 25, start: 0.24)
        let timeline = PreviewTimeline.build(clips: [
            .init(clipID: idA, pts: source, inPoint: nil, outPoint: 49,
                  duration: 4.24, conformed: true),
        ], targetFrameRate: "25/1")

        #expect(timeline.totalFrames == 55)
        // The playhead's first frames fall before the stream's first pts; they clamp
        // to the first kept frame rather than running off the index.
        let segment = timeline.segments[0]
        #expect(timeline.sourceFrame(in: segment, local: 0, pts: source) == 0)
    }

    @Test func openOutPointWindowEndsAtTheProbedDuration() {
        // No out point → the export reads to the file end, so the window ends at the
        // probed duration: 4.0 s at 25fps → 100 frames, not the 50fps source count.
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
}
