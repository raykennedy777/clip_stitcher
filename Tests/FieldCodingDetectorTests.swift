import Testing
import Foundation
@testable import ClipStitcher

/// The field-coded (PAFF) check (issue #46): measured packet cadence vs the probed
/// display rate. The rate pairs and cadences below are the *real* probed values of the
/// fixtures the acceptance criteria name — pinned so the verdicts can't drift.
struct FieldCodingDetectorTests {

    /// `count` packets spaced `interval` seconds apart.
    private func pts(interval: Double, count: Int = 200) -> [Double] {
        (0..<count).map { Double($0) * interval }
    }

    @Test func paffCaptureIsFlagged() {
        // The real 1842 capture: 50 packets/s (two fields per frame), probed
        // avg_frame_rate 50/1 (ffprobe's packet-derived rate — the field rate) and
        // r_frame_rate 25/1 (the codec's true display rate).
        #expect(FieldCodingDetector.isFieldCoded(
            packetPts: pts(interval: 0.02), frameRates: ["50/1", "25/1"]))
    }

    @Test func trueFiftyPIsNotFlagged() {
        // The real 1844 capture: 50 packets/s, both rates probe 50/1 — one packet
        // per frame.
        #expect(!FieldCodingDetector.isFieldCoded(
            packetPts: pts(interval: 0.02), frameRates: ["50/1", "50/1"]))
    }

    @Test func cleanTwentyFiveFpsIsNotFlagged() {
        // The MPEG-2 / H.264 shape: 25 packets/s, 25/1 both ways.
        #expect(!FieldCodingDetector.isFieldCoded(
            packetPts: pts(interval: 0.04), frameRates: ["25/1", "25/1"]))
    }

    @Test func fieldRateHeaderOverTruePerFramePacketsIsNotFlagged() {
        // The inverse quirk: a frame-coded interlaced file whose r_frame_rate reports
        // the *field* rate (50) over true one-packet-per-frame 25/s packets. Cadence
        // matches the lower rate 1:1 — not field-coded.
        #expect(!FieldCodingDetector.isFieldCoded(
            packetPts: pts(interval: 0.04), frameRates: ["25/1", "50/1"]))
    }

    @Test func strayTimestampAnomaliesDoNotChangeTheVerdict() {
        // Real broadcast captures carry stray duplicate/gap anomalies (the broadcast fixture
        // has ~714 — ADR-0008); the median cadence must shrug them off.
        var dirty = pts(interval: 0.04)
        dirty[50] = dirty[49]            // duplicate pts
        dirty[120] += 0.04               // a skipped slot
        #expect(!FieldCodingDetector.isFieldCoded(
            packetPts: dirty, frameRates: ["25/1", "25/1"]))
        var dirtyPaff = pts(interval: 0.02)
        dirtyPaff[50] = dirtyPaff[49]
        dirtyPaff[120] += 0.02
        #expect(FieldCodingDetector.isFieldCoded(
            packetPts: dirtyPaff, frameRates: ["50/1", "25/1"]))
    }

    @Test func thinEvidenceStaysUnflagged() {
        // Too few packets to call a cadence, or no parseable rate: never flag.
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
