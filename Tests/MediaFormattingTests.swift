import Testing
import Foundation
@testable import ClipStitcher

struct MediaFormattingTests {
    @Test func frameRateDropsDecimalsOnWholeRates() {
        #expect(MediaFormatting.frameRate("25/1") == "25")
        #expect(MediaFormatting.frameRate("50/1") == "50")
        #expect(MediaFormatting.frameRate("30000/1001") == "29.970")
        #expect(MediaFormatting.frameRate("0/0") == "0/0")
    }

    @Test func scanTypeGlossesFieldOrder() {
        #expect(MediaFormatting.scanType(nil) == "Progressive")
        #expect(MediaFormatting.scanType("") == "Progressive")
        #expect(MediaFormatting.scanType("unknown") == "Progressive")
        #expect(MediaFormatting.scanType("progressive") == "Progressive")
        #expect(MediaFormatting.scanType("tt") == "Interlaced (tt)")
        #expect(MediaFormatting.scanType("bb") == "Interlaced (bb)")
    }

    @Test func displayAspectRatioFoldsInTheSampleAspect() {
        #expect(MediaFormatting.displayAspectRatio(width: 1920, height: 1080, sar: "1:1") == "16:9")
        #expect(MediaFormatting.displayAspectRatio(width: 640, height: 480, sar: nil) == "4:3")
        #expect(MediaFormatting.displayAspectRatio(width: 720, height: 576, sar: "16:15") == "4:3")
        #expect(MediaFormatting.displayAspectRatio(width: 720, height: 576, sar: "64:45") == "16:9")
        #expect(MediaFormatting.displayAspectRatio(width: 0, height: 1080, sar: "1:1") == nil)
    }

    @Test func durationSwitchesToHoursPastAnHour() {
        #expect(MediaFormatting.duration(0) == "0:00")
        #expect(MediaFormatting.duration(65) == "1:05")
        #expect(MediaFormatting.duration(3661) == "1:01:01")
    }
}
