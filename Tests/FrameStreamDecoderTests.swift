import Testing
import Foundation
@testable import ClipStitcher

struct FrameStreamDecoderTests {
    @Test func seekSubtractsTheContainerStartTime() {
        #expect(abs(FrameStreamDecoder.seekSeconds(forPts: 30.12, containerStart: 0.24) - 29.88) < 1e-9)
    }

    @Test func zeroStartTimeSourcesSeekAtAbsolutePts() {
        #expect(FrameStreamDecoder.seekSeconds(forPts: 26.64, containerStart: 0.0) == 26.64)
    }

    @Test func seekNeverGoesNegative() {
        #expect(FrameStreamDecoder.seekSeconds(forPts: 0.2, containerStart: 0.24) == 0.0)
    }
}

struct DecoderStderrTailTests {
    @Test func boundedTailKeepsTheRecentBytesIncludingTheLastLine() {
        let tail = StderrTail(cap: 1024)
        tail.append(Data(String(repeating: "x\n", count: 5000).utf8))
        tail.append(Data("FINAL_DECODE_ERROR\n".utf8))
        let snapshot = tail.snapshot()
        let text = String(data: snapshot, encoding: .utf8) ?? ""
        #expect(text.contains("FINAL_DECODE_ERROR"))
        #expect(snapshot.count < 4096)
        #expect(!text.hasPrefix("\n"))
    }

    @Test func aCleanDecodeLeavesTheTailEmpty() {
        #expect(StderrTail(cap: 1024).snapshot().isEmpty)
    }
}
