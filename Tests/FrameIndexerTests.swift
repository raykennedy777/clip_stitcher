import Testing
@testable import ClipStitcher

struct FrameIndexerParseTests {
    @Test func keepsEveryFrameSortedIntoPresentationOrder() {
        let csv = "0.00,0.00,K__\n0.12,0.04,___\n0.04,0.08,___\n0.08,0.12,___\n"
        let index = FrameIndexer.parseIndex(csv: csv)
        #expect(index.count == 4)
        #expect(index.pts == [0.00, 0.04, 0.08, 0.12])
        #expect(index.keyframeFlags == [true, false, false, false])
    }

    @Test func fillsAMissingPtsFromTheDtsRatherThanDroppingTheFrame() {
        let csv = "0.00,0.00,K__\nN/A,0.04,___\n0.08,0.08,___\n"
        let index = FrameIndexer.parseIndex(csv: csv)
        #expect(index.count == 3)
        #expect(index.pts == [0.00, 0.04, 0.08])
        #expect(index.dts == [0.00, 0.04, 0.08])
    }

    @Test func fillsAMissingDtsFromThePts() {
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

struct FrameIndexerAllStreamsTests {
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
        #expect(scan.streams.map(\.streamIndex) == [0, 1])
        #expect(scan.streams[0].isVideo)
        #expect(!scan.streams[1].isVideo)
        #expect(scan.streams[0].packets.count == 4)
        #expect(scan.streams[1].packets.count == 2)
        #expect(scan.index.count == 4)
        #expect(scan.index.pts == [0.00, 0.04, 0.08, 0.12])
        #expect(scan.index.keyframeFlags == [true, false, false, false])
        let direct = FrameIndexer.makeIndex(scan.streams[0].packets)
        #expect(scan.index.pts == direct.pts && scan.index.dts == direct.dts
                && scan.index.keyframeFlags == direct.keyframeFlags)
    }

    @Test func indexesTheLowestNumberedVideoStream() {
        let csv = """
        video,3,9.00,9.00,K__
        video,0,0.00,0.00,K__
        video,0,0.04,0.04,___
        video,3,9.04,9.04,___
        """
        let scan = FrameIndexer.parseAllStreams(csv: csv)
        #expect(scan.streams.map(\.streamIndex) == [3, 0])
        #expect(scan.index.pts == [0.00, 0.04])
    }

    @Test func skipsMalformedLines() {
        let csv = "video,0,0.00,0.00,K__\nvideo,0,0.04\n\nvideo,x,0.08,0.08,___\n"
        let scan = FrameIndexer.parseAllStreams(csv: csv)
        #expect(scan.streams.count == 1)
        #expect(scan.index.count == 1)
    }
}

struct ScanProgressTests {
    @Test func reportsPtsFractionOfDuration() {
        var p = FrameIndexer.StreamingAllStreamsScan(duration: 10)
        #expect(p.feed("video,0,0.0,0.0,K__\naudio,1,0.0,0.0,K__\n") == 0.0)
        #expect(p.feed("video,0,2.5,2.5,___\n") == 0.25)
        #expect(p.feed("video,0,10.0,10.0,___\n") == 1.0)
    }

    @Test func rebasesToTheFirstTimestamp() {
        var p = FrameIndexer.StreamingAllStreamsScan(duration: 100)
        #expect(p.feed("video,0,1000.0,1000.0,K__\n") == 0.0)
        #expect(p.feed("video,0,1050.0,1050.0,___\n") == 0.5)
    }

    @Test func assemblesLinesSplitAcrossChunks() {
        var p = FrameIndexer.StreamingAllStreamsScan(duration: 10)
        #expect(p.feed("video,0,0.0,0.0,K__\nvideo,0,5.") == 0.0)
        #expect(p.feed("0,5.0,___\n") == 0.5)
    }

    @Test func staysMonotonicAndReturnsNilWhenNotAdvanced() {
        var p = FrameIndexer.StreamingAllStreamsScan(duration: 10)
        #expect(p.feed("video,0,0.0,0.0,K__\n") == 0.0)
        #expect(p.feed("video,0,5.0,5.0,___\n") == 0.5)
        #expect(p.feed("audio,1,3.0,3.0,___\n") == nil)
        #expect(p.feed("video,0,8.0,8.0,___\n") == 0.8)
    }

    @Test func skipsPacketsWithNoPts() {
        var p = FrameIndexer.StreamingAllStreamsScan(duration: 10)
        #expect(p.feed("video,0,0.0,0.0,K__\n") == 0.0)
        #expect(p.feed("video,0,4.0,4.0,K__\n") == 0.4)
        #expect(p.feed("video,0,,4.0,___\n") == nil)
    }

    @Test func nonPositiveDurationReportsNothing() {
        var p = FrameIndexer.StreamingAllStreamsScan(duration: 0)
        #expect(p.feed("video,0,4.0,4.0,K__\n") == nil)
    }
}

struct FrameIndexMakeIndexTests {
    @Test func fillsGapsSkipsTimestamplessAndSortsByPts() {
        let packets = [
            FrameIndexer.PacketStamp(pts: 0.00, dts: 0.00, keyframe: true),
            FrameIndexer.PacketStamp(pts: nil, dts: 0.04),
            FrameIndexer.PacketStamp(pts: 0.08, dts: nil),
            FrameIndexer.PacketStamp(pts: nil, dts: nil),
            FrameIndexer.PacketStamp(pts: 0.12, dts: 0.06),
        ]
        let index = FrameIndexer.makeIndex(packets)
        #expect(index.count == 4)
        #expect(index.pts == [0.00, 0.04, 0.08, 0.12])
        #expect(index.dts == [0.00, 0.04, 0.08, 0.06])
        #expect(index.keyframeFlags == [true, false, false, false])
    }
}
