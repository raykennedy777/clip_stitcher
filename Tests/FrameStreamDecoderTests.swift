import Testing
import Foundation
@testable import ClipStitcher

struct FrameStreamDecoderTests {

    // Input `-ss` is measured from the container's start_time, not absolute pts —
    // seeking a .mpg capture (start_time 0.24) at absolute pts lands a whole GOP
    // late and mislabels every frame in the cut editor (issue #36).
    @Test func seekSubtractsTheContainerStartTime() {
        #expect(abs(FrameStreamDecoder.seekSeconds(forPts: 30.12, containerStart: 0.24) - 29.88) < 1e-9)
    }

    @Test func zeroStartTimeSourcesSeekAtAbsolutePts() {
        #expect(FrameStreamDecoder.seekSeconds(forPts: 26.64, containerStart: 0.0) == 26.64)
    }

    // A pts at or before the container start (the very first frames) must not
    // produce a negative `-ss`.
    @Test func seekNeverGoesNegative() {
        #expect(FrameStreamDecoder.seekSeconds(forPts: 0.2, containerStart: 0.24) == 0.0)
    }
}

/// The bounded stderr tail the decoder now reuses to capture its ffmpeg's stderr (issue
/// #86) — the same `ProcessRunner` implementation, made reachable rather than forked into
/// a second copy. A flood keeps only a recent tail; the final (fatal) line survives, so a
/// persistent decode failure is diagnosable instead of silently degrading to the slow path.
struct DecoderStderrTailTests {
    @Test func boundedTailKeepsTheRecentBytesIncludingTheLastLine() {
        let tail = StderrTail(cap: 1024)
        tail.append(Data(String(repeating: "x\n", count: 5000).utf8))   // ~10 KB, past 2× cap
        tail.append(Data("FINAL_DECODE_ERROR\n".utf8))
        let snapshot = tail.snapshot()
        let text = String(data: snapshot, encoding: .utf8) ?? ""
        #expect(text.contains("FINAL_DECODE_ERROR"))   // the fatal line survives the trim
        #expect(snapshot.count < 4096)                  // bounded, not the whole ~10 KB
        #expect(!text.hasPrefix("\n"))                  // trimmed to a clean line boundary
    }

    @Test func aCleanDecodeLeavesTheTailEmpty() {
        // At -loglevel error a healthy decode writes nothing → nothing to log.
        #expect(StderrTail(cap: 1024).snapshot().isEmpty)
    }
}
