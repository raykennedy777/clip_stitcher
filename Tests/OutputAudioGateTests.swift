import Testing
import Foundation
@testable import ClipStitcher

struct OutputAudioGateTests {
    @Test func parsesEachTracksPacketsInMuxedOrder() {
        let csv = """
        1,-0.021000
        2,-0.021000
        1,0.000000
        2,0.000000,
        1,0.021333
        2,N/A
        1,0.042667,
        2,0.042667

        """
        let timelines = MediaProbe.parseAudioTimelines(csv: csv)
        #expect(timelines.count == 2)
        #expect(timelines[0].streamIndex == 1)
        #expect(timelines[0].timedPackets == 4)
        #expect(timelines[0].untimedPackets == 0)
        #expect(timelines[0].firstPts == -0.021)
        #expect(timelines[0].lastPts == 0.042667)
        #expect(timelines[0].firstNonAdvance == nil)
        #expect(timelines[1].streamIndex == 2)
        #expect(timelines[1].timedPackets == 3)
        #expect(timelines[1].untimedPackets == 1)
        #expect(timelines[1].lastPts == 0.042667)
    }

    @Test func ordersTracksByStreamIndexNotFirstAppearance() {
        let csv = "2,0.0\n1,0.0\n2,0.021333\n1,0.021333\n"
        let timelines = MediaProbe.parseAudioTimelines(csv: csv)
        #expect(timelines.map(\.streamIndex) == [1, 2])
    }

    @Test func reportsTheFirstPacketThatDoesNotAdvance() throws {
        let csv = "1,0.000000\n1,0.021333\n1,1.984000\n1,1.984000\n1,1.984000\n"
        let timeline = MediaProbe.parseAudioTimelines(csv: csv)[0]
        let stall = try #require(timeline.firstNonAdvance)
        #expect(stall.ordinal == 4)
        #expect(stall.previous == 1.984)
        #expect(stall.pts == 1.984)
    }

    @Test func aBackwardsTimestampIsAlsoAStall() throws {
        let csv = "1,0.000000\n1,0.021333\n1,0.010000\n"
        let stall = try #require(MediaProbe.parseAudioTimelines(csv: csv)[0].firstNonAdvance)
        #expect(stall.ordinal == 3)
        #expect(stall.pts == 0.01)
    }

    @Test func anUntimedPacketIsNotAStall() {
        let csv = "1,0.000000\n1,N/A\n1,0.021333\n"
        let timeline = MediaProbe.parseAudioTimelines(csv: csv)[0]
        #expect(timeline.firstNonAdvance == nil)
        #expect(timeline.timedPackets == 2)
        #expect(timeline.untimedPackets == 1)
    }

    @Test func measuresTheTracksOwnPacketInterval() throws {
        let aac = MediaProbe.AudioTimeline(streamIndex: 1, timedPackets: 330,
                                           firstPts: -0.021, lastPts: 6.997)
        let interval = try #require(aac.packetInterval)
        #expect(abs(interval - 0.021331) < 0.000001)
        #expect(abs(try #require(aac.span) - 7.018) < 0.0001)
        #expect(MediaProbe.AudioTimeline(streamIndex: 1, timedPackets: 1,
                                         firstPts: 0, lastPts: 0).packetInterval == nil)
    }

    struct CleanRender: Sendable, CustomTestStringConvertible {
        var label: String
        var packets: Int
        var first: Double
        var last: Double
        var planned: Double
        var testDescription: String { label }
    }

    @Test(arguments: [
        CleanRender(label: "mkv/aac", packets: 330, first: -0.0210, last: 6.9970, planned: 7.0),
        CleanRender(label: "mp4/aac", packets: 330, first: -0.0213, last: 6.9973, planned: 7.0),
        CleanRender(label: "ts/mp2", packets: 292, first: 1.4300, last: 8.4140, planned: 7.0),
        CleanRender(label: "mkv/mp2", packets: 292, first: -0.0100, last: 6.9740, planned: 7.0),
        CleanRender(label: "mkv/ac3", packets: 219, first: -0.0050, last: 6.9710, planned: 7.0),
        CleanRender(label: "mkv/libmp3lame", packets: 293, first: -0.0230, last: 6.9850, planned: 7.0),
        CleanRender(label: "audio-only/aac", packets: 330, first: 0.0, last: 7.0187, planned: 7.0),
        CleanRender(label: "audio-only/ac3", packets: 219, first: 0.0, last: 6.9760, planned: 7.0),
        CleanRender(label: "real mpeg-2/mp2", packets: 1034, first: 0.0, last: 24.7920, planned: 24.8),
        CleanRender(label: "real mpeg-2/aac", packets: 1164, first: 0.0, last: 24.8107, planned: 24.8),
        CleanRender(label: "real hevc 4.5h/mp2", packets: 3992, first: 0.0, last: 95.7840, planned: 95.8),
        CleanRender(label: "tiny keeps/aac", packets: 9, first: 0.0, last: 0.1707, planned: 0.16),
    ])
    func aCleanRenderPasses(render: CleanRender) {
        let timeline = MediaProbe.AudioTimeline(streamIndex: 1, timedPackets: render.packets,
                                                firstPts: render.first, lastPts: render.last)
        #expect(ExportEngine.audioTimelineDefect(timelines: [timeline], expectedTracks: 1,
                                                 expectedExtent: render.planned) == nil,
                "\(render.label) must pass the gate")
    }

    @Test func theNormalPrimingOffsetDoesNotTripTheGate() {
        for priming in [-0.010, -0.0213, -0.021] {
            let timeline = MediaProbe.AudioTimeline(streamIndex: 1, timedPackets: 330,
                                                    firstPts: priming, lastPts: 6.997)
            #expect(ExportEngine.audioTimelineDefect(timelines: [timeline], expectedTracks: 1,
                                                     expectedExtent: 7.0) == nil,
                    "priming of \(priming) s must not fail the gate")
        }
    }

    @Test func oneAudioFrameOfTailDifferenceIsNormal() {
        let frame = 0.021333
        for shift in [-frame, frame, -2 * frame] {
            let timeline = MediaProbe.AudioTimeline(streamIndex: 1, timedPackets: 330,
                                                    firstPts: 0, lastPts: 7.0 - frame + shift)
            #expect(ExportEngine.audioTimelineDefect(timelines: [timeline], expectedTracks: 1,
                                                     expectedExtent: 7.0) == nil,
                    "a \(shift) s tail difference must not fail the gate")
        }
    }

    @Test func withoutAPlannedSpanTheExtentCheckSkipsAndTheRestStillApplies() {
        let short = MediaProbe.AudioTimeline(streamIndex: 1, timedPackets: 330,
                                             firstPts: 0, lastPts: 2.0)
        #expect(ExportEngine.audioTimelineDefect(timelines: [short], expectedTracks: 1,
                                                 expectedExtent: nil) == nil)
        let stalled = MediaProbe.AudioTimeline(
            streamIndex: 1, timedPackets: 330, firstPts: 0, lastPts: 2.0,
            firstNonAdvance: .init(ordinal: 97, previous: 1.984, pts: 1.984))
        #expect(ExportEngine.audioTimelineDefect(timelines: [stalled], expectedTracks: 1,
                                                 expectedExtent: nil) != nil)
        let empty = MediaProbe.AudioTimeline(streamIndex: 1, timedPackets: 0, untimedPackets: 12)
        let defect = ExportEngine.audioTimelineDefect(timelines: [empty], expectedTracks: 1,
                                                      expectedExtent: nil)
        #expect(defect != nil)
        #expect(defect?.contains("12") == true, "the message should say what the track did carry")
    }

    @Test func aCollapsedTimelineFailsNamingTheTrackAndPosition() throws {
        let timeline = MediaProbe.AudioTimeline(
            streamIndex: 1, timedPackets: 330, firstPts: -0.021, lastPts: 1.984,
            firstNonAdvance: .init(ordinal: 96, previous: 1.984, pts: 1.984))
        let defect = try #require(ExportEngine.audioTimelineDefect(
            timelines: [timeline], expectedTracks: 1, expectedExtent: 7.0))
        #expect(defect.contains("track 1"))
        #expect(defect.contains("96"))
        #expect(defect.contains("1.984"))
    }

    @Test func aCollapsedTimelineMaskedByTheMp4MuxerStillFailsOnExtent() throws {
        let timeline = MediaProbe.AudioTimeline(streamIndex: 1, timedPackets: 330,
                                                firstPts: -0.0213, lastPts: 1.9889)
        let defect = try #require(ExportEngine.audioTimelineDefect(
            timelines: [timeline], expectedTracks: 1, expectedExtent: 7.0))
        #expect(defect.contains("track 1"))
        #expect(defect.contains("2.016"))
        #expect(defect.contains("7.000"))
    }

    @Test func aMultiTrackOutputNamesTheFailingTrack() throws {
        let good = MediaProbe.AudioTimeline(streamIndex: 1, timedPackets: 330,
                                            firstPts: -0.021, lastPts: 6.997)
        let bad = MediaProbe.AudioTimeline(
            streamIndex: 2, timedPackets: 330, firstPts: -0.021, lastPts: 1.984,
            firstNonAdvance: .init(ordinal: 96, previous: 1.984, pts: 1.984))
        let defect = try #require(ExportEngine.audioTimelineDefect(
            timelines: [good, bad], expectedTracks: 2, expectedExtent: 7.0))
        #expect(defect.contains("track 2"))
        #expect(!defect.contains("track 1"))
    }

    @Test func aStallIsReportedAheadOfTheShortExtentItCauses() throws {
        let timeline = MediaProbe.AudioTimeline(
            streamIndex: 1, timedPackets: 330, firstPts: 0, lastPts: 1.984,
            firstNonAdvance: .init(ordinal: 96, previous: 1.984, pts: 1.984))
        let defect = try #require(ExportEngine.audioTimelineDefect(
            timelines: [timeline], expectedTracks: 1, expectedExtent: 7.0))
        #expect(defect.contains("stops advancing"))
    }

    @Test func aMissingOrEmptyTrackFails() {
        let one = MediaProbe.AudioTimeline(streamIndex: 1, timedPackets: 330,
                                           firstPts: -0.021, lastPts: 6.997)
        #expect(ExportEngine.audioTimelineDefect(timelines: [one], expectedTracks: 2,
                                                 expectedExtent: 7.0) != nil)
        #expect(ExportEngine.audioTimelineDefect(timelines: [], expectedTracks: 1,
                                                 expectedExtent: 7.0) != nil)
        let empty = MediaProbe.AudioTimeline(streamIndex: 1, timedPackets: 0)
        #expect(ExportEngine.audioTimelineDefect(timelines: [empty], expectedTracks: 1,
                                                 expectedExtent: 7.0) != nil)
    }

    @Test func aSingleFrameKeepWithOnePacketPasses() {
        let timeline = MediaProbe.AudioTimeline(streamIndex: 1, timedPackets: 1,
                                                firstPts: 0, lastPts: 0)
        #expect(ExportEngine.audioTimelineDefect(timelines: [timeline], expectedTracks: 1,
                                                 expectedExtent: 1.0 / 60) == nil)
        #expect(ExportEngine.audioTimelineDefect(timelines: [timeline], expectedTracks: 1,
                                                 expectedExtent: 7.0) != nil)
    }

    @Test func theToleranceIsFarBelowTheDefectItSeparates() {
        #expect(ExportEngine.audioExtentToleranceFrames >= 2)
        #expect(ExportEngine.audioExtentToleranceFrames <= 10)
    }
}
