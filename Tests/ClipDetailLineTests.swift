import Foundation
import Testing
@testable import VidConform

/// The Source view's clip-row detail line (issue #11): it must summarize the clip's
/// *edited* audio track list (ADR-0014's slots), not the source file's probed streams.
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
        // Four probed streams cut down to one slot in Audio Settings: the row must
        // say one track (no count suffix), not "4 audio tracks".
        var clip = videoClip()
        clip.audio = track(codec: "mp2")
        clip.audioTracks = [clip.audio!, track(), track(), track()]
        clip.audioSelections = [.stream(0)]
        #expect(ClipRowView.detailLine(for: clip)
                == "H264 1024×576 · 50 fps · MP2 2ch 48kHz")
    }

    @Test func externalTrackInSlotOneDrivesTheSummaryAndCount() {
        // One own stream plus an external AC3 file promoted to slot 1: two tracks,
        // and the codec summary describes the external, not the probed first stream.
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

    @Test func zeroSlotsShowNoAudioSegment() {
        var clip = videoClip()
        clip.audio = track(codec: "mp2")
        clip.audioTracks = [clip.audio!]
        clip.audioSelections = []
        #expect(ClipRowView.detailLine(for: clip) == "H264 1024×576 · 50 fps")
    }

    @Test func unknownFirstSlotStillShowsTheTrackCount() {
        // Slot 1 is an unprobed external (no codec to describe), slot 2 is known:
        // skip the codec summary but keep the audio visible via the count.
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
        clip.audioSelections = [.stream(3)]  // out-of-range: properties unknown
        #expect(ClipRowView.detailLine(for: clip)
                == "H264 1024×576 · 50 fps · 1 audio track")
    }
}
