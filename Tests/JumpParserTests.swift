import Foundation
import Testing
@testable import ClipStitcher

/// Jump popover parsing (issue #21): lenient timecode and frame fields, with
/// relative (offset) and absolute (from the clip's first frame) resolution.
struct JumpParserTests {
    @Test func frameFieldParsesIntegersIncludingNegative() {
        #expect(JumpParser.frames("1500") == 1500)
        #expect(JumpParser.frames(" -100 ") == -100)
        #expect(JumpParser.frames("abc") == nil)
        #expect(JumpParser.frames("") == nil)
        #expect(JumpParser.frames("1.5") == nil)
    }

    @Test func bareSecondsConvert() {
        // Bare seconds convert to frames: 70 seconds is 1:10.
        #expect(JumpParser.timecodeFrames("70", fps: 25) == 1750)
    }

    @Test func minutesSecondsConvert() {
        #expect(JumpParser.timecodeFrames("1:10", fps: 25) == 1750)
    }

    @Test func fullTimecodeMatchesTheReadoutArithmetic() {
        #expect(JumpParser.timecodeFrames("00:01:00:00", fps: 25) == 1500)
        #expect(JumpParser.timecodeFrames("00:00:01:05", fps: 25) == 30)
        #expect(JumpParser.timecodeFrames("01:02:03:04", fps: 25) == (3723 * 25) + 4)
    }

    @Test func ntscRatesUseTheRoundedFps() {
        // Same rounding as the readout: 30000/1001 counts 30 frames per second.
        #expect(JumpParser.timecodeFrames("0:0:1:0", fps: 29.97) == 30)
    }

    @Test func semicolonsAndWhitespaceAreAccepted() {
        #expect(JumpParser.timecodeFrames(" 00;00;01;00 ", fps: 25) == 25)
    }

    @Test func leadingMinusNegatesForRelativeJumps() {
        #expect(JumpParser.timecodeFrames("-1:00", fps: 25) == -1500)
    }

    @Test func malformedTimecodesAreRejected() {
        #expect(JumpParser.timecodeFrames("", fps: 25) == nil)
        #expect(JumpParser.timecodeFrames("::", fps: 25) == nil)
        #expect(JumpParser.timecodeFrames("1:xx", fps: 25) == nil)
        #expect(JumpParser.timecodeFrames("1:2:3:4:5", fps: 25) == nil)
        #expect(JumpParser.timecodeFrames("1:-2", fps: 25) == nil)
    }

    @Test func relativeTargetsOffsetFromTheCurrentFrame() {
        #expect(JumpParser.target(value: 100, relative: true, current: 1000) == 1100)
        #expect(JumpParser.target(value: -100, relative: true, current: 1000) == 900)
    }

    @Test func absoluteTargetsCountFromTheClipStart() {
        #expect(JumpParser.target(value: 1500, relative: false, current: 1000) == 1500)
    }
}
