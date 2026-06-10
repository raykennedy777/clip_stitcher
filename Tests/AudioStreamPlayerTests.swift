import Testing
@testable import VidConform

/// The pure parts of cut-editor audio playback (issue #7): the PCM decode command
/// and the start_time-aware seek math. The streaming/engine side is verified at
/// runtime (subprocess-spawning tests hang the test runner).
struct AudioStreamPlayerTests {
    @Test func argumentsDecodeOneStreamToStereo48kFloatOnStdout() {
        let args = AudioStreamPlayer.arguments(
            filePath: "/tmp/clip.mkv", streamIndex: 2, seekSeconds: 10.5)
        #expect(args == [
            "-v", "error",
            "-ss", "10.500000",
            "-i", "/tmp/clip.mkv",
            "-map", "0:a:2", "-vn",
            "-f", "f32le", "-ac", "2", "-ar", "48000",
            "-",
        ])
    }

    /// Input -ss is measured from the container's start_time, not absolute pts —
    /// on the 0.24 s-start MPEG-PS clip, seeking to pts 10.24 needs `-ss 10.0`
    /// (measured: `-ss 10.24` lands at 10.48, exactly start_time late).
    @Test func seekSubtractsTheContainerStartTime() {
        #expect(AudioStreamPlayer.seekSeconds(sourceTime: 10.24, containerStartTime: 0.24) == 10.0)
        #expect(AudioStreamPlayer.seekSeconds(sourceTime: 0.040, containerStartTime: 0.0) == 0.040)
    }

    /// A frame whose pts precedes the container start (possible when another stream
    /// starts earlier) must not produce a negative seek.
    @Test func seekClampsAtTheFileStart() {
        #expect(AudioStreamPlayer.seekSeconds(sourceTime: 0.1, containerStartTime: 0.24) == 0.0)
    }
}

/// The audio-clocked playback loop maps elapsed audio time back to the frame on
/// screen: the last frame whose pts is at or before the clock time.
struct FrameIndexTimeLookupTests {
    private let index = FrameIndex(
        pts: [0.24, 0.28, 0.32, 0.36, 0.40],
        keyframeFlags: [true, false, false, false, false]
    )

    @Test func exactFrameTimesMapToThatFrame() {
        #expect(index.frameIndex(atOrBeforeTime: 0.24) == 0)
        #expect(index.frameIndex(atOrBeforeTime: 0.36) == 3)
    }

    @Test func timesBetweenFramesMapToTheEarlierFrame() {
        #expect(index.frameIndex(atOrBeforeTime: 0.30) == 1)
        #expect(index.frameIndex(atOrBeforeTime: 0.3999) == 3)
    }

    @Test func timesOutsideTheStreamClampToTheEnds() {
        #expect(index.frameIndex(atOrBeforeTime: 0.0) == 0)
        #expect(index.frameIndex(atOrBeforeTime: 99.0) == 4)
    }
}
