import Testing
import Foundation
@testable import ClipStitcher

struct OpenGopSpliceTests {
    private func nal(_ type: Int, body: Int = 6) -> [UInt8] {
        [UInt8(type << 1), 0x01] + Array(repeating: 0xAB, count: body)
    }

    private func lengthPrefixed(_ units: [[UInt8]]) -> [UInt8] {
        units.flatMap { u -> [UInt8] in
            let n = u.count
            return [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + u
        }
    }

    private func annexB(_ units: [[UInt8]]) -> [UInt8] {
        units.flatMap { [0, 0, 0, 1] + $0 }
    }

    @Test func theWalkFindsEverySliceOfTheFirstCRA() {
        let bytes = lengthPrefixed([nal(32), nal(33), nal(34), nal(39), nal(21), nal(21), nal(1)])
        #expect(OpenGopSplice.irapHeaderOffsets(in: bytes, framing: .lengthPrefixed) == [52, 64])
        let stream = annexB([nal(35), nal(32), nal(21), nal(8)])
        #expect(OpenGopSplice.irapHeaderOffsets(in: stream, framing: .annexB) == [28])
    }

    @Test func aFirstPictureOfAnotherTypeIsRefused() {
        for first in [19, 20, 1, 0, 8] {
            #expect(OpenGopSplice.irapHeaderOffsets(
                in: lengthPrefixed([nal(32), nal(first), nal(21)]), framing: .lengthPrefixed) == nil)
        }
        #expect(OpenGopSplice.irapHeaderOffsets(in: lengthPrefixed([nal(32), nal(34)]),
                                                framing: .lengthPrefixed) == nil)
    }

    @Test func lengthsThatDoNotTileThePacketAreRefused() {
        var bytes = lengthPrefixed([nal(32), nal(21)])
        bytes.append(0x00)
        #expect(OpenGopSplice.irapHeaderOffsets(in: bytes, framing: .lengthPrefixed) == nil)
    }

    @Test func theRewriteChangesOnlyTheTypeBits() {
        #expect(OpenGopSplice.blaHeaderByte(0x2A) == 0x24)
        #expect(OpenGopSplice.blaHeaderByte(0x2B) == 0x25)
        #expect(OpenGopSplice.blaHeaderByte(0x22) == 0x24)
        #expect(Int(OpenGopSplice.blaHeaderByte(0x2A) >> 1) == OpenGopSplice.blaNoLeading)
    }

    private func tsPacket(start: Bool, adaptation: Int?, payload: [UInt8]) -> [UInt8] {
        var p: [UInt8] = [0x47, (start ? 0x40 : 0) | 0x01, 0x00]
        var room = 184
        if let adaptation {
            p.append(0x30)
            p += [UInt8(adaptation)] + Array(repeating: 0xFF, count: adaptation)
            room -= 1 + adaptation
        } else {
            p.append(0x10)
        }
        precondition(payload.count <= room)
        return p + payload + Array(repeating: 0xFF, count: room - payload.count)
    }

    @Test func aTsPesPayloadMapsEachByteToItsFilePosition() throws {
        let pes: [UInt8] = [0, 0, 1, 0xE0, 0, 0, 0x80, 0x80, 0x05, 0x21, 0, 1, 0, 1]
        let elementary = annexB([nal(35, body: 1), nal(32, body: 140), nal(21, body: 60)])
        let all = pes + elementary
        let firstRoom = 184 - 1 - 7
        let craHeader = pes.count + 4 + 3 + 4 + 142 + 4
        let split = craHeader + 1
        precondition(split <= firstRoom)
        let pad = firstRoom - split
        let first = tsPacket(start: true, adaptation: 7 + pad, payload: Array(all[0..<split]))
        let second = tsPacket(start: false, adaptation: nil, payload: Array(all[split...]))
        let next = tsPacket(start: true, adaptation: nil, payload: [0, 0, 1, 0xE0])
        let file = first + second + next
        let payload = try #require(OpenGopSplice.tsPesPayload(file))
        #expect(Array(payload.payload.prefix(elementary.count)) == elementary)
        let offsets = try #require(OpenGopSplice.irapHeaderOffsets(in: payload.payload, framing: .annexB))
        #expect(offsets.count == 1)
        let position = payload.positions[offsets[0]]
        #expect(position == 187)
        #expect(file[position] == 0x2A)
        #expect(file[payload.positions[offsets[0] + 1]] == 0x01)
    }

    @Test func aTsBufferWithoutAUnitStartIsRefused() {
        #expect(OpenGopSplice.tsPesPayload(tsPacket(start: false, adaptation: nil, payload: [1])) == nil)
        #expect(OpenGopSplice.tsPesPayload([0x47, 0x40]) == nil)
    }

    private let index = FrameIndex(
        pts: [0, 0.02, 0.04, 0.06, 0.08, 0.10],
        dts: [-0.04, 0.0, -0.02, 0.06, 0.04, 0.08],
        keyframeFlags: [true, false, false, false, true, false])

    @Test func theDropFilterIsWrittenOnTheSeekShift() {
        let filter = OpenGopSplice.leadingPictureDropFilter(
            keyframe: 4, count: 1, index: index, containerStart: 1.0, seek: 0.5)
        #expect(filter == "noise=drop='gte(dts*tb\\,-1.465)*lt(pts*tb\\,-1.425)',"
                + "setts=pts=PTS:dts='if(lt(abs(PTS*TB-(-1.42))\\,0.005)\\,-1.44/TB\\,DTS)'")
    }

    @Test func theDropRunsFirstInTheCopyChain() {
        #expect(OpenGopSplice.prependingDrop("noise", to: []) == ["-bsf:v", "noise"])
        #expect(OpenGopSplice.prependingDrop("noise", to: ["-bsf:v", "hevc_mp4toannexb"])
                == ["-bsf:v", "noise,hevc_mp4toannexb"])
    }

    @Test func theTimingLineNamesTheDroppedPictures() {
        let line = BoundaryReencodeEngine.segmentTimingLine(
            clipIndex: 1, segment: 1,
            planned: PlannedSegment(kind: .copy, range: 750..<1500, droppedLeadingPictures: 1),
            seconds: 0.04)
        #expect(line == "clip 1 s1 copy [750,1500): 0.04 s, 750 frames, 1 leading picture dropped")
    }

    @Test func onlySpliceFailuresFallBack() {
        #expect(ExportEngine.spliceFailureFallsBack(.verificationFailed("x")))
        #expect(ExportEngine.spliceFailureFallsBack(.cutFailed("x")))
        #expect(ExportEngine.spliceFailureFallsBack(.concatFailed("x")))
        #expect(ExportEngine.spliceFailureFallsBack(.missingSegment))
        #expect(!ExportEngine.spliceFailureFallsBack(.cancelled(finished: 0, total: 1)))
        #expect(!ExportEngine.spliceFailureFallsBack(.invalidPlan))
    }
}
