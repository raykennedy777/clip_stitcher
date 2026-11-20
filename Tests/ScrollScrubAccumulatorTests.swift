import Testing
@testable import ClipStitcher

struct ScrollScrubAccumulatorTests {
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

    @Test func aTinyWheelDeltaStillStepsAWholeFrame() {
        var acc = ScrollScrubAccumulator()
        #expect(acc.frameSteps(deltaY: 0.1, precise: false, momentum: false) == -1)
    }

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
        #expect(acc.frameSteps(deltaY: 0.5 * perFrame, precise: true, momentum: false) == -1)
    }

    @Test func reversingDirectionUnwindsTheCarryFirst() {
        var acc = ScrollScrubAccumulator()
        #expect(acc.frameSteps(deltaY: 4, precise: true, momentum: false) == 0)
        #expect(acc.frameSteps(deltaY: -4, precise: true, momentum: false) == 0)
        let perFrame = ScrollScrubAccumulator.pointsPerFrame
        #expect(acc.frameSteps(deltaY: -perFrame, precise: true, momentum: false) == 1)
    }

    @Test func momentumEventsNeverStepAndNeverTouchTheCarry() {
        var acc = ScrollScrubAccumulator()
        #expect(acc.frameSteps(deltaY: 4, precise: true, momentum: false) == 0)
        #expect(acc.frameSteps(deltaY: 500, precise: true, momentum: true) == 0)
        let perFrame = ScrollScrubAccumulator.pointsPerFrame
        #expect(acc.frameSteps(deltaY: perFrame - 4, precise: true, momentum: false) == -1)
    }

    @Test func aZeroDeltaEventDoesNothing() {
        var acc = ScrollScrubAccumulator()
        #expect(acc.frameSteps(deltaY: 0, precise: true, momentum: false) == 0)
        #expect(acc.frameSteps(deltaY: 0, precise: false, momentum: false) == 0)
    }

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

struct JumpFieldSteppingTests {
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

    @Test func lenientInputReRendersAsFullTimecode() {
        #expect(JumpParser.steppedTimecode("4:24", by: 1, fps: 25, allowNegative: false) == "00:04:24:01")
    }

    @Test func anUnparsableTimeFieldIsLeftAlone() {
        #expect(JumpParser.steppedTimecode("nonsense", by: 1, fps: 25, allowNegative: true) == nil)
    }
}
