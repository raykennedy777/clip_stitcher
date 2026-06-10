import Testing
@testable import VidConform

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
