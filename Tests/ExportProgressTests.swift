import Testing
import Foundation
@testable import ClipStitcher

/// Exercises the pure export-progress math (issue #9): `-progress pipe:1` line parsing
/// and incremental chunk assembly, the out_time → overall-fraction mapping (keeping the
/// 70 % video / 30 % audio phase split), and the damped "About X remaining" estimate.
/// The parsing facts pinned here were de-risked in the shell on all three formats.
struct ExportProgressTests {
    // MARK: -progress line parsing

    @Test func progressArgumentsPrefixTheRun() {
        #expect(ExportProgress.progressArguments(["-v", "error", "-i", "in.mp4"])
                == ["-progress", "pipe:1", "-nostats", "-v", "error", "-i", "in.mp4"])
    }

    /// `out_time_us` and `out_time_ms` are BOTH microseconds (the historical ffmpeg
    /// quirk — de-risked: a 9.36 s stream-copy reports 9360000 in both).
    @Test func outTimeMicrosecondKeysParseToSeconds() {
        #expect(ExportProgress.outTimeSeconds(fromLine: "out_time_us=9360000") == 9.36)
        #expect(ExportProgress.outTimeSeconds(fromLine: "out_time_ms=9360000") == 9.36)
    }

    @Test func outTimeClockParsesAndOtherLinesDoNot() {
        #expect(ExportProgress.outTimeSeconds(fromLine: "out_time=01:07:00.400000") == 4020.4)
        #expect(ExportProgress.outTimeSeconds(fromLine: "frame=235") == nil)
        #expect(ExportProgress.outTimeSeconds(fromLine: "progress=continue") == nil)
        #expect(ExportProgress.outTimeSeconds(fromLine: "") == nil)
    }

    /// Before the first frame ffmpeg can emit `N/A`; a piece's leading edge can dip
    /// negative. Neither may produce a bogus time.
    @Test func outTimeSkipsNAAndClampsNegatives() {
        #expect(ExportProgress.outTimeSeconds(fromLine: "out_time_us=N/A") == nil)
        #expect(ExportProgress.outTimeSeconds(fromLine: "out_time_us=-40000") == 0)
    }

    /// stdout chunks split lines arbitrarily; the partial tail must be held back until
    /// its newline arrives, and the latest out_time in a chunk wins.
    @Test func streamAssemblesSplitLinesAcrossChunks() {
        var stream = ExportProgress.Stream()
        #expect(stream.feed("frame=10\nout_ti") == nil)
        #expect(stream.feed("me_us=2000000\nprogress=continue\n") == 2.0)
        #expect(stream.feed("out_time_us=3000000\nout_time_us=4000000\n") == 4.0)
    }

    // MARK: fraction mapping

    @Test func runFractionClampsAndNeedsAnExpectation() {
        #expect(ExportProgress.runFraction(outTime: 5, expectedSeconds: 10) == 0.5)
        #expect(ExportProgress.runFraction(outTime: 12, expectedSeconds: 10) == 1.0)   // final-block overshoot
        #expect(ExportProgress.runFraction(outTime: 5, expectedSeconds: nil) == 0)     // unknown → hold at base
        #expect(ExportProgress.runFraction(outTime: 5, expectedSeconds: 0) == 0)
    }

    /// Within-clip progress weights the plan's segment runs by frame count: with
    /// [2, 5, 2] frames and the middle run half done, 2 + 2.5 of 9 frames are through.
    @Test func withinClipWeightsSegmentsByFrameCount() {
        let w = ExportProgress.withinClip(segmentFrames: [2, 5, 2], completedSegments: 1,
                                          currentRunFraction: 0.5)
        #expect(abs(w - 4.5 / 9) < 1e-9)
        #expect(ExportProgress.withinClip(segmentFrames: [2, 5, 2], completedSegments: 3,
                                          currentRunFraction: 0) == 1.0)
        #expect(ExportProgress.withinClip(segmentFrames: [], completedSegments: 0,
                                          currentRunFraction: 0.5) == 0)
    }

    /// The overall mapping keeps the established 70/30 phase split: clip i of n spans
    /// its share of the first 70 %, the `.connect` mux fills the last 30 %, and
    /// `.separate` splits that 30 % per clip.
    @Test func overallFractionsKeepTheSeventyThirtySplit() {
        #expect(abs(ExportProgress.clipFraction(clipIndex: 0, clipCount: 2, withinClip: 0.5) - 0.175) < 1e-9)
        #expect(abs(ExportProgress.clipFraction(clipIndex: 1, clipCount: 2, withinClip: 1.0) - 0.7) < 1e-9)
        #expect(abs(ExportProgress.muxFraction(withinMux: 0.5) - 0.85) < 1e-9)
        #expect(abs(ExportProgress.separateFraction(clipIndex: 1, clipCount: 2, withinMux: 0.5) - 0.925) < 1e-9)
    }

    // MARK: ETA estimate

    /// No estimate before 2 % progress and 2 s elapsed — too little signal to show.
    @Test func etaWithholdsEarlyEstimates() {
        var eta = ExportProgress.ETAEstimator()
        #expect(eta.update(fraction: 0.01, elapsed: 30) == nil)
        #expect(eta.update(fraction: 0.5, elapsed: 1) == nil)
    }

    /// The first estimate is the raw throughput projection; later ones are damped
    /// toward it (EMA), so a phase change (stream-copy → re-encode) can't swing the
    /// readout to the new raw value in one step.
    @Test func etaDampsTowardNewThroughput() {
        var eta = ExportProgress.ETAEstimator()
        #expect(eta.update(fraction: 0.25, elapsed: 10) == 30)          // raw: 10 × 3
        let second = eta.update(fraction: 0.25, elapsed: 30)            // raw jumps to 90
        #expect(abs((second ?? 0) - (0.7 * 30 + 0.3 * 90)) < 1e-9)      // pulled, not snapped
    }

    // MARK: ETA label (HIG: round numbers, no false precision)

    @Test func etaLabelShowsNothingWithoutAnEstimate() {
        #expect(ExportProgress.etaLabel(remaining: nil, fraction: 0.5) == nil)
    }

    @Test func etaLabelFinishesUpNearTheEnd() {
        #expect(ExportProgress.etaLabel(remaining: 8, fraction: 0.5) == "Finishing up…")
        #expect(ExportProgress.etaLabel(remaining: 300, fraction: 0.98) == "Finishing up…")
    }

    @Test func etaLabelRoundsUpThroughTheBands() {
        #expect(ExportProgress.etaLabel(remaining: 34, fraction: 0.5) == "About 40 seconds remaining")
        #expect(ExportProgress.etaLabel(remaining: 55, fraction: 0.5) == "About a minute remaining")
        #expect(ExportProgress.etaLabel(remaining: 200, fraction: 0.5) == "About 4 minutes remaining")
        #expect(ExportProgress.etaLabel(remaining: 3500, fraction: 0.5) == "About an hour remaining")
        #expect(ExportProgress.etaLabel(remaining: 5300, fraction: 0.5) == "About 1½ hours remaining")
        #expect(ExportProgress.etaLabel(remaining: 7300, fraction: 0.5) == "About 2 hours remaining")
    }
}
