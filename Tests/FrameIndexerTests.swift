import Testing
@testable import VidConform

/// Exercises the pure CSV→index parsing. The frame index must keep one entry per decoded
/// frame: the cut editor numbers frames by it and the export cuts by it, so a dropped
/// frame desyncs the two and makes cuts land wrong (a long MPEG-2 file with 436 N/A-pts
/// packets shifted the numbering and leaked stream-copied frames past the count).
struct FrameIndexerParseTests {
    @Test func keepsEveryFrameSortedIntoPresentationOrder() {
        // Decode-order packets with B-frame reorder; index is sorted by pts.
        let csv = "0.00,0.00,K__\n0.12,0.04,___\n0.04,0.08,___\n0.08,0.12,___\n"
        let index = FrameIndexer.parseIndex(csv: csv, codec: "h264")
        #expect(index.count == 4)
        #expect(index.pts == [0.00, 0.04, 0.08, 0.12])
        #expect(index.keyframeFlags == [true, false, false, false])
    }

    @Test func fillsAMissingPtsFromTheDtsRatherThanDroppingTheFrame() {
        // A scattered B-frame with pts=N/A still counts, ordered by its dts. Dropping it
        // would shrink the index below the true frame count (the real-file bug).
        let csv = "0.00,0.00,K__\nN/A,0.04,___\n0.08,0.08,___\n"
        let index = FrameIndexer.parseIndex(csv: csv, codec: "mpeg2video")
        #expect(index.count == 3)
        #expect(index.pts == [0.00, 0.04, 0.08])   // N/A pts filled from dts 0.04
        #expect(index.dts == [0.00, 0.04, 0.08])
    }

    @Test func fillsAMissingDtsFromThePts() {
        // The first packet often has dts=N/A; it falls back to the pts.
        let csv = "0.00,N/A,K__\n0.04,0.04,___\n"
        let index = FrameIndexer.parseIndex(csv: csv, codec: "hevc")
        #expect(index.count == 2)
        #expect(index.dts == [0.00, 0.04])
    }

    @Test func skipsOnlyAPacketWithNoTimestampAtAll() {
        let csv = "0.00,0.00,K__\nN/A,N/A,___\n0.04,0.04,___\n"
        let index = FrameIndexer.parseIndex(csv: csv, codec: "h264")
        #expect(index.count == 2)
    }
}
