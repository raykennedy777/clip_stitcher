import Testing
@testable import ClipStitcher

/// Exercises the pure CSV→index parsing. The frame index must keep one entry per decoded
/// frame: the cut editor numbers frames by it and the export cuts by it, so a dropped
/// frame desyncs the two and makes cuts land wrong (a long MPEG-2 file with 436 N/A-pts
/// packets shifted the numbering and leaked stream-copied frames past the count).
struct FrameIndexerParseTests {
    @Test func keepsEveryFrameSortedIntoPresentationOrder() {
        // Decode-order packets with B-frame reorder; index is sorted by pts.
        let csv = "0.00,0.00,K__\n0.12,0.04,___\n0.04,0.08,___\n0.08,0.12,___\n"
        let index = FrameIndexer.parseIndex(csv: csv)
        #expect(index.count == 4)
        #expect(index.pts == [0.00, 0.04, 0.08, 0.12])
        #expect(index.keyframeFlags == [true, false, false, false])
    }

    @Test func fillsAMissingPtsFromTheDtsRatherThanDroppingTheFrame() {
        // A scattered B-frame with pts=N/A still counts, ordered by its dts. Dropping it
        // would shrink the index below the true frame count (the real-file bug).
        let csv = "0.00,0.00,K__\nN/A,0.04,___\n0.08,0.08,___\n"
        let index = FrameIndexer.parseIndex(csv: csv)
        #expect(index.count == 3)
        #expect(index.pts == [0.00, 0.04, 0.08])   // N/A pts filled from dts 0.04
        #expect(index.dts == [0.00, 0.04, 0.08])
    }

    @Test func fillsAMissingDtsFromThePts() {
        // The first packet often has dts=N/A; it falls back to the pts.
        let csv = "0.00,N/A,K__\n0.04,0.04,___\n"
        let index = FrameIndexer.parseIndex(csv: csv)
        #expect(index.count == 2)
        #expect(index.dts == [0.00, 0.04])
    }

    @Test func skipsOnlyAPacketWithNoTimestampAtAll() {
        let csv = "0.00,0.00,K__\nN/A,N/A,___\n0.04,0.04,___\n"
        let index = FrameIndexer.parseIndex(csv: csv)
        #expect(index.count == 2)
    }
}

/// The all-streams scan (issue #45): one demux pass widened to every audio/video stream
/// (`codec_type,stream_index,pts_time,dts_time,flags` CSV), so import gets the frame index
/// and the damage detector's per-stream packet timing from a single read.
struct FrameIndexerAllStreamsTests {
    /// Groups packets by stream in container order, keeps only audio/video (a TS also
    /// carries teletext/data whose sparse timing would read as fake gaps), and assembles
    /// the frame index from the video stream — identical to what `parseIndex` would build
    /// from the same packets, so the two reads can never disagree about frame numbering.
    @Test func groupsAudioAndVideoAndIndexesTheVideoStream() {
        let csv = """
        video,0,0.00,0.00,K__
        audio,1,0.00,0.00,K__
        data,2,0.00,0.00,___
        video,0,0.12,0.04,___
        video,0,0.04,0.08,___
        video,0,0.08,0.12,___
        audio,1,0.04,0.04,___
        """
        let scan = FrameIndexer.parseAllStreams(csv: csv)
        // The data stream is dropped; video then audio, in container order.
        #expect(scan.streams.map(\.streamIndex) == [0, 1])
        #expect(scan.streams[0].isVideo)
        #expect(!scan.streams[1].isVideo)
        #expect(scan.streams[0].packets.count == 4)
        #expect(scan.streams[1].packets.count == 2)
        // The index is the video stream's packets sorted into presentation order.
        #expect(scan.index.count == 4)
        #expect(scan.index.pts == [0.00, 0.04, 0.08, 0.12])
        #expect(scan.index.keyframeFlags == [true, false, false, false])
        // Identical to assembling the index from the video stream's packets directly.
        let direct = FrameIndexer.makeIndex(scan.streams[0].packets)
        #expect(scan.index.pts == direct.pts && scan.index.dts == direct.dts
                && scan.index.keyframeFlags == direct.keyframeFlags)
    }

    /// The index is built from the **lowest-numbered** video stream even when a
    /// higher-numbered video stream demuxes first.
    @Test func indexesTheLowestNumberedVideoStream() {
        let csv = """
        video,3,9.00,9.00,K__
        video,0,0.00,0.00,K__
        video,0,0.04,0.04,___
        video,3,9.04,9.04,___
        """
        let scan = FrameIndexer.parseAllStreams(csv: csv)
        #expect(scan.streams.map(\.streamIndex) == [3, 0])   // demux order preserved
        #expect(scan.index.pts == [0.00, 0.04])              // but the index is stream 0's
    }

    /// Malformed lines (too few fields, an unparsable stream index, a blank line) are
    /// skipped rather than crashing the scan.
    @Test func skipsMalformedLines() {
        let csv = "video,0,0.00,0.00,K__\nvideo,0,0.04\n\nvideo,x,0.08,0.08,___\n"
        let scan = FrameIndexer.parseAllStreams(csv: csv)
        #expect(scan.streams.count == 1)
        #expect(scan.index.count == 1)
    }
}

/// The streamed verify-scan progress signal (issue #81): the greatest `pts_time` seen so
/// far, rebased to the first stamp, over the scan duration. Drives the Clip Doctor
/// 0.97→1.0 band so a multi-minute network re-scan advances instead of freezing.
struct ScanProgressTests {
    /// pts climbs with the scan; the fraction tracks it against the total duration.
    @Test func reportsPtsFractionOfDuration() {
        var p = FrameIndexer.StreamingAllStreamsScan(duration: 10)
        #expect(p.feed("video,0,0.0,0.0,K__\naudio,1,0.0,0.0,K__\n") == 0.0)
        #expect(p.feed("video,0,2.5,2.5,___\n") == 0.25)
        #expect(p.feed("video,0,10.0,10.0,___\n") == 1.0)
    }

    /// A TS pts starts at an arbitrary clock offset, so progress rebases to the first
    /// stamp — a scan whose pts begins at 1000 s isn't reported as already complete.
    @Test func rebasesToTheFirstTimestamp() {
        var p = FrameIndexer.StreamingAllStreamsScan(duration: 100)
        #expect(p.feed("video,0,1000.0,1000.0,K__\n") == 0.0)
        #expect(p.feed("video,0,1050.0,1050.0,___\n") == 0.5)
    }

    /// A chunk can split a line anywhere; the partial tail is held until its newline.
    @Test func assemblesLinesSplitAcrossChunks() {
        var p = FrameIndexer.StreamingAllStreamsScan(duration: 10)
        #expect(p.feed("video,0,0.0,0.0,K__\nvideo,0,5.") == 0.0)   // "5." held back
        #expect(p.feed("0,5.0,___\n") == 0.5)
    }

    /// Strictly non-decreasing: an out-of-order or lower pts never rewinds the bar, and a
    /// chunk that adds no later timestamp returns nil rather than re-poking it.
    @Test func staysMonotonicAndReturnsNilWhenNotAdvanced() {
        var p = FrameIndexer.StreamingAllStreamsScan(duration: 10)
        #expect(p.feed("video,0,0.0,0.0,K__\n") == 0.0)   // baseline
        #expect(p.feed("video,0,5.0,5.0,___\n") == 0.5)
        #expect(p.feed("audio,1,3.0,3.0,___\n") == nil)   // earlier stamp: no advance
        #expect(p.feed("video,0,8.0,8.0,___\n") == 0.8)
    }

    /// A missing pts (a damaged truncated packet) is skipped, not read as zero.
    @Test func skipsPacketsWithNoPts() {
        var p = FrameIndexer.StreamingAllStreamsScan(duration: 10)
        #expect(p.feed("video,0,0.0,0.0,K__\n") == 0.0)   // baseline
        #expect(p.feed("video,0,4.0,4.0,K__\n") == 0.4)
        #expect(p.feed("video,0,,4.0,___\n") == nil)      // empty pts_time field
    }

    /// A non-positive duration yields no signal rather than dividing by zero.
    @Test func nonPositiveDurationReportsNothing() {
        var p = FrameIndexer.StreamingAllStreamsScan(duration: 0)
        #expect(p.feed("video,0,4.0,4.0,K__\n") == nil)
    }
}

/// `makeIndex` is the shared index-assembly core (the same rules `parseIndex` and
/// `parseAllStreams` both feed into): fill a missing pts from the dts, a missing dts from
/// the pts, skip a packet that carries neither, then sort into presentation order.
struct FrameIndexMakeIndexTests {
    @Test func fillsGapsSkipsTimestamplessAndSortsByPts() {
        let packets = [
            FrameIndexer.PacketStamp(pts: 0.00, dts: 0.00, keyframe: true),
            FrameIndexer.PacketStamp(pts: nil, dts: 0.04),    // pts filled from dts
            FrameIndexer.PacketStamp(pts: 0.08, dts: nil),    // dts filled from pts
            FrameIndexer.PacketStamp(pts: nil, dts: nil),     // skipped: no timestamp
            FrameIndexer.PacketStamp(pts: 0.12, dts: 0.06),   // out of order
        ]
        let index = FrameIndexer.makeIndex(packets)
        #expect(index.count == 4)
        #expect(index.pts == [0.00, 0.04, 0.08, 0.12])
        #expect(index.dts == [0.00, 0.04, 0.08, 0.06])
        #expect(index.keyframeFlags == [true, false, false, false])
    }
}
