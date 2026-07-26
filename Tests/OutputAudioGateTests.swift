import Testing
import Foundation
@testable import ClipStitcher

/// The pure core of the output audio gate (issue #112): the per-track timeline facts read
/// off a written file (`MediaProbe.parseAudioTimelines`) and the verdict passed on them
/// (`ExportEngine.audioTimelineDefect`).
///
/// Every number here is **measured**, not invented — from the shell de-risk of the real
/// mux recipe over synthetic MPEG-2/H.264/HEVC sources and over a real broadcast MPEG-2
/// capture, in `.mkv`, `.mp4` and `.ts`, with each audio encoder the policy can pick
/// (aac/mp2/ac3/libmp3lame). A clean render's extent came out between +0.00 and +1.88
/// audio frames longer than the plan, never short; the collapsed render (the pre-#111
/// graph) came out 717–819 frames short. The gate has to separate those two populations
/// without touching the first.
struct OutputAudioGateTests {

    // MARK: - Reading the timeline facts

    /// The dump the gate reads: `packet=stream_index,pts_time -of csv=p=0` over
    /// `-select_streams a`. Two tracks interleaved in muxed order, an "N/A" packet (a
    /// demuxer that carries no timestamp for one packet), and the trailing-comma rows
    /// ffprobe's CSV writer emits on some streams.
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

    /// Tracks come back ordered by stream index however the packets interleave, so the
    /// array position is the output audio track (numbered from 1 for the user).
    @Test func ordersTracksByStreamIndexNotFirstAppearance() {
        let csv = "2,0.0\n1,0.0\n2,0.021333\n1,0.021333\n"
        let timelines = MediaProbe.parseAudioTimelines(csv: csv)
        #expect(timelines.map(\.streamIndex) == [1, 2])
    }

    /// The collapse of issue #111 as the dump shows it: consecutive packets on one
    /// timestamp. The first such packet is reported with its position, so the message can
    /// say where the timeline stopped.
    @Test func reportsTheFirstPacketThatDoesNotAdvance() throws {
        let csv = "1,0.000000\n1,0.021333\n1,1.984000\n1,1.984000\n1,1.984000\n"
        let timeline = MediaProbe.parseAudioTimelines(csv: csv)[0]
        let stall = try #require(timeline.firstNonAdvance)
        #expect(stall.ordinal == 4)          // 1-based among the track's timed packets
        #expect(stall.previous == 1.984)
        #expect(stall.pts == 1.984)
    }

    /// A timestamp going *backwards* is the same defect class as a repeat.
    @Test func aBackwardsTimestampIsAlsoAStall() throws {
        let csv = "1,0.000000\n1,0.021333\n1,0.010000\n"
        let stall = try #require(MediaProbe.parseAudioTimelines(csv: csv)[0].firstNonAdvance)
        #expect(stall.ordinal == 3)
        #expect(stall.pts == 0.01)
    }

    /// An untimed packet can't be ordered, so it takes part in neither check — it must not
    /// read as a stall against the packet before it.
    @Test func anUntimedPacketIsNotAStall() {
        let csv = "1,0.000000\n1,N/A\n1,0.021333\n"
        let timeline = MediaProbe.parseAudioTimelines(csv: csv)[0]
        #expect(timeline.firstNonAdvance == nil)
        #expect(timeline.timedPackets == 2)
        #expect(timeline.untimedPackets == 1)
    }

    /// The measured interval is the tolerance's unit, so it is read off the track itself
    /// rather than assumed: aac packs 1024 samples (21.3 ms at 48 kHz), mp2/mp3 1152
    /// (24 ms), ac3 1536 (32 ms).
    @Test func measuresTheTracksOwnPacketInterval() throws {
        let aac = MediaProbe.AudioTimeline(streamIndex: 1, timedPackets: 330,
                                           firstPts: -0.021, lastPts: 6.997)
        let interval = try #require(aac.packetInterval)
        #expect(abs(interval - 0.021331) < 0.000001)
        #expect(abs(try #require(aac.span) - 7.018) < 0.0001)
        // Below two timed packets there is no interval to measure and no span.
        #expect(MediaProbe.AudioTimeline(streamIndex: 1, timedPackets: 1,
                                         firstPts: 0, lastPts: 0).packetInterval == nil)
    }

    // MARK: - The verdict: clean renders pass

    /// One measured render: what its audio track's packets came out as, and the span the
    /// plan asked for.
    struct CleanRender: Sendable, CustomTestStringConvertible {
        var label: String
        var packets: Int
        var first: Double
        var last: Double
        var planned: Double
        var testDescription: String { label }
    }

    /// Every clean render measured in the de-risk, as its facts: three video codecs
    /// (identical audio-side numbers), three containers, four audio encoders, plus the real
    /// broadcast MPEG-2 capture and a real 4.5 h HEVC capture. None may trip the gate.
    ///
    /// The `.ts` row is the reason the extent is measured **first packet to last** and never
    /// as an absolute timestamp: the mpegts muxer starts the timeline at its own clock base
    /// (1.43 s here), which says nothing about how much audio the track holds.
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

    /// The priming trap called out in the issue: our exports legitimately start the audio
    /// ~10–21 ms *before* the video, which is deliberate compensation, not a sync defect.
    /// It shows up as a first packet before zero, which the gate must read as an extent one
    /// frame long — not as a fault.
    @Test func theNormalPrimingOffsetDoesNotTripTheGate() {
        for priming in [-0.010, -0.0213, -0.021] {
            let timeline = MediaProbe.AudioTimeline(streamIndex: 1, timedPackets: 330,
                                                    firstPts: priming, lastPts: 6.997)
            #expect(ExportEngine.audioTimelineDefect(timelines: [timeline], expectedTracks: 1,
                                                     expectedExtent: 7.0) == nil,
                    "priming of \(priming) s must not fail the gate")
        }
    }

    /// One audio frame of tail difference is normal in both directions (the reporter
    /// measured 34 ms on a good render and correctly called it normal).
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

    /// With no expectation to check against — any clip missing a kept duration — the extent
    /// check has nothing to say and must skip rather than guess. Everything that needs no
    /// expectation still applies: a stalled timeline, and a track that carries nothing at all.
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
        // A track with no timestamped audio is the defect the gate exists for; an unknown
        // planned span must not excuse it.
        let empty = MediaProbe.AudioTimeline(streamIndex: 1, timedPackets: 0, untimedPackets: 12)
        let defect = ExportEngine.audioTimelineDefect(timelines: [empty], expectedTracks: 1,
                                                      expectedExtent: nil)
        #expect(defect != nil)
        #expect(defect?.contains("12") == true, "the message should say what the track did carry")
    }

    // MARK: - The verdict: broken renders fail

    /// The collapse in MKV, where the duplicate timestamps are visible: the message names
    /// the audio track and where the timeline stopped.
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

    /// The same collapse in **MP4**, which masks it: the muxer bumps the duplicate
    /// timestamps apart, so there is no stall to find and only the extent gives it away
    /// (2.016 s of a planned 7 s). This is why the gate needs both checks.
    @Test func aCollapsedTimelineMaskedByTheMp4MuxerStillFailsOnExtent() throws {
        let timeline = MediaProbe.AudioTimeline(streamIndex: 1, timedPackets: 330,
                                                firstPts: -0.0213, lastPts: 1.9889)
        let defect = try #require(ExportEngine.audioTimelineDefect(
            timelines: [timeline], expectedTracks: 1, expectedExtent: 7.0))
        #expect(defect.contains("track 1"))
        #expect(defect.contains("2.016"))     // measured
        #expect(defect.contains("7.000"))     // expected
    }

    /// A multi-track output names the track that failed, not just "the audio".
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

    /// A stall is the more specific diagnosis than the short extent it causes, so it is
    /// what the message leads with when a track has both.
    @Test func aStallIsReportedAheadOfTheShortExtentItCauses() throws {
        let timeline = MediaProbe.AudioTimeline(
            streamIndex: 1, timedPackets: 330, firstPts: 0, lastPts: 1.984,
            firstNonAdvance: .init(ordinal: 96, previous: 1.984, pts: 1.984))
        let defect = try #require(ExportEngine.audioTimelineDefect(
            timelines: [timeline], expectedTracks: 1, expectedExtent: 7.0))
        #expect(defect.contains("stops advancing"))
    }

    /// A track the mux was supposed to write but the file doesn't carry, and a file whose
    /// audio track holds no packets at all — both are "the audio didn't survive", which is
    /// exactly what the gate exists to refuse.
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

    /// A track too short to measure its own interval isn't a defect by itself — a
    /// single-frame keep in a 1536-sample codec really is one packet — so the nominal
    /// audio frame stands in and only a plan far past it fails.
    @Test func aSingleFrameKeepWithOnePacketPasses() {
        let timeline = MediaProbe.AudioTimeline(streamIndex: 1, timedPackets: 1,
                                                firstPts: 0, lastPts: 0)
        #expect(ExportEngine.audioTimelineDefect(timelines: [timeline], expectedTracks: 1,
                                                 expectedExtent: 1.0 / 60) == nil)
        #expect(ExportEngine.audioTimelineDefect(timelines: [timeline], expectedTracks: 1,
                                                 expectedExtent: 7.0) != nil)
    }

    /// No export can pass the gate with an extent an order of magnitude off, whatever the
    /// codec's frame size sets the tolerance to.
    @Test func theToleranceIsFarBelowTheDefectItSeparates() {
        // Measured: clean renders sat within +1.88 audio frames, the collapse 717 short.
        #expect(ExportEngine.audioExtentToleranceFrames >= 2)
        #expect(ExportEngine.audioExtentToleranceFrames <= 10)
    }
}
