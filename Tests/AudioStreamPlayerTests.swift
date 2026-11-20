import Testing
@testable import ClipStitcher

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

    @Test func seekSubtractsTheContainerStartTime() {
        #expect(AudioStreamPlayer.seekSeconds(sourceTime: 10.24, containerStartTime: 0.24) == 10.0)
        #expect(AudioStreamPlayer.seekSeconds(sourceTime: 0.040, containerStartTime: 0.0) == 0.040)
    }

    @Test func seekClampsAtTheFileStart() {
        #expect(AudioStreamPlayer.seekSeconds(sourceTime: 0.1, containerStartTime: 0.24) == 0.0)
    }
}

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

struct AudioStreamPlayerPreviewArgumentTests {
    @Test func filterAndDurationSlotIntoTheDecodeCommand() {
        let args = AudioStreamPlayer.arguments(
            filePath: "/tmp/clip.mkv", streamIndex: 1, seekSeconds: 11.6,
            filter: "aresample=48000,aformat=channel_layouts=stereo", duration: 2.4)
        #expect(args == [
            "-v", "error",
            "-ss", "11.600000",
            "-t", "2.400000",
            "-i", "/tmp/clip.mkv",
            "-map", "0:a:1", "-vn",
            "-af", "aresample=48000,aformat=channel_layouts=stereo",
            "-f", "f32le", "-ac", "2", "-ar", "48000",
            "-",
        ])
    }

    @Test func silenceLegGeneratesEngineFormatSilenceForTheLegDuration() {
        #expect(AudioStreamPlayer.silenceArguments(duration: 2.0) == [
            "-v", "error",
            "-t", "2.000000",
            "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo",
            "-f", "f32le", "-ac", "2", "-ar", "48000",
            "-",
        ])
    }
}
