import Testing
import Foundation
@testable import ClipStitcher

struct FieldCodingDetectorTests {
    private func pts(interval: Double, count: Int = 200) -> [Double] {
        (0..<count).map { Double($0) * interval }
    }

    @Test func paffCaptureIsFlagged() {
        #expect(FieldCodingDetector.isFieldCoded(
            packetPts: pts(interval: 0.02), frameRates: ["50/1", "25/1"]))
    }

    @Test func trueFiftyPIsNotFlagged() {
        #expect(!FieldCodingDetector.isFieldCoded(
            packetPts: pts(interval: 0.02), frameRates: ["50/1", "50/1"]))
    }

    @Test func cleanTwentyFiveFpsIsNotFlagged() {
        #expect(!FieldCodingDetector.isFieldCoded(
            packetPts: pts(interval: 0.04), frameRates: ["25/1", "25/1"]))
    }

    @Test func fieldRateHeaderOverTruePerFramePacketsIsNotFlagged() {
        #expect(!FieldCodingDetector.isFieldCoded(
            packetPts: pts(interval: 0.04), frameRates: ["25/1", "50/1"]))
    }

    @Test func strayTimestampAnomaliesDoNotChangeTheVerdict() {
        var dirty = pts(interval: 0.04)
        dirty[50] = dirty[49]
        dirty[120] += 0.04
        #expect(!FieldCodingDetector.isFieldCoded(
            packetPts: dirty, frameRates: ["25/1", "25/1"]))
        var dirtyPaff = pts(interval: 0.02)
        dirtyPaff[50] = dirtyPaff[49]
        dirtyPaff[120] += 0.02
        #expect(FieldCodingDetector.isFieldCoded(
            packetPts: dirtyPaff, frameRates: ["50/1", "25/1"]))
    }

    @Test func thinEvidenceStaysUnflagged() {
        #expect(!FieldCodingDetector.isFieldCoded(
            packetPts: pts(interval: 0.02, count: 10), frameRates: ["50/1", "25/1"]))
        #expect(!FieldCodingDetector.isFieldCoded(
            packetPts: [], frameRates: ["50/1", "25/1"]))
        #expect(!FieldCodingDetector.isFieldCoded(
            packetPts: pts(interval: 0.02), frameRates: [nil, ""]))
        #expect(!FieldCodingDetector.isFieldCoded(
            packetPts: pts(interval: 0.02), frameRates: ["0/0", "25/0"]))
    }

    @Test func medianIntervalNeedsTwentyFiveIntervals() {
        let median = FieldCodingDetector.medianInterval((0..<26).map { Double($0) * 0.02 })
        #expect(median != nil && abs(median! - 0.02) < 1e-9)
        #expect(FieldCodingDetector.medianInterval((0..<25).map { Double($0) * 0.02 }) == nil)
    }
}
