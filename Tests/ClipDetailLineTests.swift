import Foundation
import Testing
@testable import ClipStitcher

struct ClipDetailLineTests {
    private func track(codec: String = "aac", sampleRate: Int = 48000, channels: Int = 2,
                       title: String? = nil) -> AudioProperties {
        AudioProperties(codec: codec, sampleRate: sampleRate, channels: channels,
                        channelLayout: nil, title: title)
    }

    private func videoClip() -> Clip {
        var clip = Clip(bookmark: Data(), displayName: "race.mkv")
        clip.video = VideoProperties(codec: "h264", width: 1024, height: 576,
                                     frameRate: "50/1", pixelFormat: "yuv420p")
        return clip
    }

    @Test func neverEditedClipSummarizesItsOwnStreams() {
        var clip = videoClip()
        clip.audio = track(codec: "mp2", sampleRate: 48000, channels: 2)
        clip.audioTracks = [clip.audio!, track(), track(), track()]
        #expect(ClipRowView.detailLine(for: clip)
                == "H264 1024×576 · 50 fps · MP2 2ch 48kHz · 4 audio tracks")
    }

    @Test func removingSlotsLowersTheCount() {
        var clip = videoClip()
        clip.audio = track(codec: "mp2")
        clip.audioTracks = [clip.audio!, track(), track(), track()]
        clip.audioSelections = [.stream(0)]
        #expect(ClipRowView.detailLine(for: clip)
                == "H264 1024×576 · 50 fps · MP2 2ch 48kHz")
    }

    @Test func externalTrackInSlotOneDrivesTheSummaryAndCount() {
        var clip = videoClip()
        clip.audio = track(codec: "mp2")
        clip.audioTracks = [clip.audio!]
        clip.audioSelections = [
            .external(bookmark: Data(), name: "commentary.ac3", streamIndex: 0,
                      tracks: [track(codec: "ac3", sampleRate: 44100, channels: 6)],
                      duration: nil),
            .stream(0),
        ]
        #expect(ClipRowView.detailLine(for: clip)
                == "H264 1024×576 · 50 fps · AC3 6ch 44kHz · 2 audio tracks")
    }

    @Test func interlacedClipNamesItsFieldOrder() {
        var clip = videoClip()
        clip.video?.fieldOrder = "tt"
        clip.audioSelections = []
        #expect(ClipRowView.detailLine(for: clip)
                == "H264 1024×576 · 50 fps · interlaced (tt)")
    }

    @Test func progressiveClipReadsProgressive() {
        var clip = videoClip()
        clip.video?.fieldOrder = "progressive"
        clip.audioSelections = []
        #expect(ClipRowView.detailLine(for: clip)
                == "H264 1024×576 · 50 fps · progressive")
    }

    @Test func unknownFieldOrderReadsProgressive() {
        var clip = videoClip()
        clip.video?.fieldOrder = "unknown"
        clip.audioSelections = []
        #expect(ClipRowView.detailLine(for: clip)
                == "H264 1024×576 · 50 fps · progressive")
    }

    @Test func zeroSlotsShowNoAudioSegment() {
        var clip = videoClip()
        clip.audio = track(codec: "mp2")
        clip.audioTracks = [clip.audio!]
        clip.audioSelections = []
        #expect(ClipRowView.detailLine(for: clip) == "H264 1024×576 · 50 fps")
    }

    @Test func unknownFirstSlotStillShowsTheTrackCount() {
        var clip = videoClip()
        clip.audio = track(codec: "mp2")
        clip.audioTracks = [clip.audio!]
        clip.audioSelections = [
            .external(bookmark: Data(), name: "mystery.wav", streamIndex: 0,
                      tracks: nil, duration: nil),
            .stream(0),
        ]
        #expect(ClipRowView.detailLine(for: clip)
                == "H264 1024×576 · 50 fps · 2 audio tracks")
    }

    @Test func singleUnknownSlotStillShowsAudioExists() {
        var clip = videoClip()
        clip.audioSelections = [.stream(3)]
        #expect(ClipRowView.detailLine(for: clip)
                == "H264 1024×576 · 50 fps · 1 audio track")
    }

    @Test func copiedShareTextRoundsButNeverInflatesTo100() {
        #expect(ClipRowView.copiedShareText(fraction: 0) == "0% copied")
        #expect(ClipRowView.copiedShareText(fraction: 0.921) == "92% copied")
        #expect(ClipRowView.copiedShareText(fraction: 0.999) == "99% copied")
        #expect(ClipRowView.copiedShareText(fraction: 1.0) == "100% copied")
    }
}
