import Testing
import Foundation
@testable import ClipStitcher

/// The spellings of the CLI's stage-timing lines (R5 of the 2026 R16 review). The slot
/// logs grep these, so their shape is pinned here.
struct StageClockTests {
    @Test func aRunTotalPrintsAsHoursMinutesSecondsAndTenths() {
        #expect(StageClock.clockLabel(0) == "00:00:00.0")
        #expect(StageClock.clockLabel(64.54) == "00:01:04.5")
        #expect(StageClock.clockLabel(3 * 3600 + 7 * 60 + 9.96) == "03:07:10.0")
    }

    @Test func aStageTimePrintsInSecondsToTheHundredth() {
        #expect(StageClock.label(9.814) == "9.81 s")
    }

    @Test func fpsNeedsFramesAndMeasurableTime() {
        #expect(StageClock.fpsLabel(frames: 1240, seconds: 25.6) == "48.4 fps")
        #expect(StageClock.fpsLabel(frames: 0, seconds: 1) == nil)
        #expect(StageClock.fpsLabel(frames: 10, seconds: 0) == nil)
    }

    @Test func segmentLinesNameKindRangeAndRate() {
        let line = BoundaryReencodeEngine.segmentTimingLine(
            clipIndex: 3, segment: 0, planned: PlannedSegment(kind: .reEncode, range: 1234..<14682),
            seconds: 291.2)
        #expect(line == "clip 3 s0 reEncode [1234,14682): 291.20 s, 13448 frames, 46.2 fps")
        let copy = BoundaryReencodeEngine.segmentTimingLine(
            clipIndex: 3, segment: 1, planned: PlannedSegment(kind: .copy, range: 14682..<56790),
            seconds: 12)
        #expect(copy == "clip 3 s1 copy [14682,56790): 12.00 s, 42108 frames")
    }
}
