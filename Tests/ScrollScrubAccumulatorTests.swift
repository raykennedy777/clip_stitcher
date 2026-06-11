import Testing
@testable import VidConform

/// The scroll-to-scrub step math (issue #40). Direction follows page meaning:
/// positive deltaY — the gesture that scrolls a webpage toward its top — moves
/// the playhead backward, so frame steps come out negative.
struct ScrollScrubAccumulatorTests {
    // MARK: - Mouse wheel (non-precise deltas): one notch = one frame

    @Test func oneWheelNotchTowardPageTopStepsOneFrameBack() {
        var acc = ScrollScrubAccumulator()
        #expect(acc.frameSteps(deltaY: 1, precise: false, momentum: false) == -1)
    }

    @Test func oneWheelNotchTowardPageBottomStepsOneFrameForward() {
        var acc = ScrollScrubAccumulator()
        #expect(acc.frameSteps(deltaY: -1, precise: false, momentum: false) == 1)
    }

    @Test func coalescedWheelNotchesStepOneFrameEach() {
        var acc = ScrollScrubAccumulator()
        #expect(acc.frameSteps(deltaY: -3, precise: false, momentum: false) == 3)
    }

    /// Some wheel drivers report sub-1.0 line deltas; a notch must still move
    /// a frame, never get swallowed by accumulation.
    @Test func aTinyWheelDeltaStillStepsAWholeFrame() {
        var acc = ScrollScrubAccumulator()
        #expect(acc.frameSteps(deltaY: 0.1, precise: false, momentum: false) == -1)
    }

    // MARK: - Trackpad (precise deltas): points accumulate toward a threshold

    @Test func aSlowTrackpadDragAccumulatesAcrossEventsBeforeStepping() {
        var acc = ScrollScrubAccumulator()
        #expect(acc.frameSteps(deltaY: 4, precise: true, momentum: false) == 0)
        #expect(acc.frameSteps(deltaY: 4, precise: true, momentum: false) == 0)
        #expect(acc.frameSteps(deltaY: 4, precise: true, momentum: false) == -1)
    }

    @Test func aFastTrackpadEventYieldsMultipleSteps() {
        var acc = ScrollScrubAccumulator()
        let perFrame = ScrollScrubAccumulator.pointsPerFrame
        #expect(acc.frameSteps(deltaY: -3.5 * perFrame, precise: true, momentum: false) == 3)
    }

    @Test func theRemainderCarriesIntoTheNextEvent() {
        var acc = ScrollScrubAccumulator()
        let perFrame = ScrollScrubAccumulator.pointsPerFrame
        #expect(acc.frameSteps(deltaY: 2.5 * perFrame, precise: true, momentum: false) == -2)
        // Half a frame is carried, so half more completes the next step.
        #expect(acc.frameSteps(deltaY: 0.5 * perFrame, precise: true, momentum: false) == -1)
    }

    @Test func reversingDirectionUnwindsTheCarryFirst() {
        var acc = ScrollScrubAccumulator()
        #expect(acc.frameSteps(deltaY: 4, precise: true, momentum: false) == 0)
        #expect(acc.frameSteps(deltaY: -4, precise: true, momentum: false) == 0)
        let perFrame = ScrollScrubAccumulator.pointsPerFrame
        #expect(acc.frameSteps(deltaY: -perFrame, precise: true, momentum: false) == 1)
    }

    // MARK: - Momentum (coasting after fingers lift) is ignored entirely

    @Test func momentumEventsNeverStepAndNeverTouchTheCarry() {
        var acc = ScrollScrubAccumulator()
        #expect(acc.frameSteps(deltaY: 4, precise: true, momentum: false) == 0)
        #expect(acc.frameSteps(deltaY: 500, precise: true, momentum: true) == 0)
        // The pre-momentum carry (4 pt) is still intact.
        let perFrame = ScrollScrubAccumulator.pointsPerFrame
        #expect(acc.frameSteps(deltaY: perFrame - 4, precise: true, momentum: false) == -1)
    }

    @Test func aZeroDeltaEventDoesNothing() {
        var acc = ScrollScrubAccumulator()
        #expect(acc.frameSteps(deltaY: 0, precise: true, momentum: false) == 0)
        #expect(acc.frameSteps(deltaY: 0, precise: false, momentum: false) == 0)
    }

    // MARK: - Shifted wheels arrive axis-swapped (macOS scrolls them sideways)

    @Test func aShiftedWheelWithAnEmptyVerticalDeltaFallsBackToHorizontal() {
        #expect(ScrollScrubAccumulator.effectiveDeltaY(
            deltaY: 0, deltaX: -1, precise: false, shift: true) == -1)
    }

    @Test func withoutShiftTheHorizontalDeltaStaysIgnored() {
        #expect(ScrollScrubAccumulator.effectiveDeltaY(
            deltaY: 0, deltaX: -3, precise: false, shift: false) == 0)
    }

    @Test func aShiftedTrackpadKeepsItsVerticalDelta() {
        #expect(ScrollScrubAccumulator.effectiveDeltaY(
            deltaY: -12, deltaX: -30, precise: true, shift: true) == -12)
    }

    @Test func aShiftedWheelThatStillCarriesAVerticalDeltaUsesIt() {
        #expect(ScrollScrubAccumulator.effectiveDeltaY(
            deltaY: 2, deltaX: -1, precise: false, shift: true) == 2)
    }
}

/// Scrolling over a jump-popover field rolls that field's staged text (issue
/// #40, decision 6): ±1 frame per step, re-rendered in place — never a live
/// jump. Absolute mode clamps at frame 0; relative mode may go negative.
struct JumpFieldSteppingTests {
    // MARK: - Frame field

    @Test func theFrameFieldStepsByWholeFrames() {
        #expect(JumpParser.steppedFrames("100", by: 1, allowNegative: false) == "101")
        #expect(JumpParser.steppedFrames("100", by: -1, allowNegative: false) == "99")
    }

    @Test func absoluteFrameZeroClampsInsteadOfGoingNegative() {
        #expect(JumpParser.steppedFrames("0", by: -1, allowNegative: false) == "0")
    }

    @Test func relativeFramesMayGoNegative() {
        #expect(JumpParser.steppedFrames("0", by: -1, allowNegative: true) == "-1")
        #expect(JumpParser.steppedFrames("-1", by: 1, allowNegative: true) == "0")
    }

    @Test func anUnparsableFrameFieldIsLeftAlone() {
        #expect(JumpParser.steppedFrames("abc", by: 1, allowNegative: true) == nil)
    }

    // MARK: - Time field (rolled-over timecode at the clip's fps)

    @Test func theTimeFieldRollsOverAtTheSecondBoundary() {
        #expect(JumpParser.steppedTimecode("00:00:04:24", by: -1, fps: 25, allowNegative: false) == "00:00:04:23")
        #expect(JumpParser.steppedTimecode("00:00:04:24", by: 1, fps: 25, allowNegative: false) == "00:00:05:00")
    }

    @Test func absoluteTimeZeroClampsInsteadOfGoingNegative() {
        #expect(JumpParser.steppedTimecode("00:00:00:00", by: -1, fps: 25, allowNegative: false) == "00:00:00:00")
    }

    @Test func relativeTimeMayGoNegative() {
        #expect(JumpParser.steppedTimecode("00:00:00:00", by: -1, fps: 25, allowNegative: true) == "-00:00:00:01")
        #expect(JumpParser.steppedTimecode("-00:00:00:01", by: 1, fps: 25, allowNegative: true) == "00:00:00:00")
    }

    /// Lenient input ("4:24" is M:S, like the parser) re-renders in the full
    /// readout shape after a step.
    @Test func lenientInputReRendersAsFullTimecode() {
        #expect(JumpParser.steppedTimecode("4:24", by: 1, fps: 25, allowNegative: false) == "00:04:24:01")
    }

    @Test func anUnparsableTimeFieldIsLeftAlone() {
        #expect(JumpParser.steppedTimecode("nonsense", by: 1, fps: 25, allowNegative: true) == nil)
    }
}
