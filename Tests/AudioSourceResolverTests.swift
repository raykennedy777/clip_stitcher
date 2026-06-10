import Testing
import Foundation
@testable import VidConform

/// Exercises the one audio source resolver behind preview playback and export
/// (ADR-0014): turning a clip's audio track selections into concrete sources, with the
/// missing-external-file policy explicit (preview degrades to silence, export throws),
/// and the output-track derivation (count from the richest clip, formats target-first).
struct AudioSourceResolverTests {

    private func track(language: String? = nil, title: String? = nil) -> AudioProperties {
        AudioProperties(codec: "aac", sampleRate: 48000, channels: 2,
                        channelLayout: "stereo", language: language, title: title)
    }

    // MARK: source resolution

    @Test func defaultSelectionResolvesToOwnStreamsInOrder() throws {
        var clip = Clip(bookmark: Data(), displayName: "multi.mkv")
        clip.audioTracks = [track(title: "A"), track(title: "B")]
        let sources = try AudioSourceResolver.resolveSources(for: clip, missingExternal: .throwError)
        #expect(sources == [.stream(0), .stream(1)])
    }

    @Test func outOfRangeOwnStreamIsSilenceUnderBothPolicies() throws {
        // The slot exists because a richer clip has it; this clip fills it with silence —
        // never an error, on either side (ADR-0014).
        var clip = Clip(bookmark: Data(), displayName: "a.mp4")
        clip.audioTracks = [track()]
        clip.audioSelections = [.stream(0), .stream(7)]
        #expect(try AudioSourceResolver.resolveSources(for: clip, missingExternal: .degradeToSilence)
                == [.stream(0), nil])
        #expect(try AudioSourceResolver.resolveSources(for: clip, missingExternal: .throwError)
                == [.stream(0), nil])
    }

    @Test func externalFileResolvesToItsURLAndChosenStream() throws {
        // A live external file: bookmark resolves, file exists — both policies agree.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vidconform-resolver-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("commentary.mp3")
        try Data().write(to: file)
        let bookmark = try file.bookmarkData()

        var clip = Clip(bookmark: Data(), displayName: "a.mp4")
        clip.audioTracks = [track()]
        clip.audioSelections = [.stream(0),
                                .external(bookmark: bookmark, name: "commentary.mp3",
                                          streamIndex: 1, tracks: nil, duration: nil)]
        for policy in [AudioSourceResolver.MissingExternalPolicy.degradeToSilence, .throwError] {
            let sources = try AudioSourceResolver.resolveSources(for: clip, missingExternal: policy)
            #expect(sources.count == 2)
            guard case .external(let url, let stream)? = sources[1] else {
                Issue.record("expected an external source")
                return
            }
            #expect(url.lastPathComponent == "commentary.mp3")
            #expect(stream == 1)
        }
    }

    @Test func deadBookmarkDegradesToSilenceForThePreview() throws {
        var clip = Clip(bookmark: Data(), displayName: "a.mp4")
        clip.audioTracks = [track()]
        clip.audioSelections = [.stream(0),
                                .external(bookmark: Data(), name: "gone.ac3",
                                          streamIndex: 0, tracks: nil, duration: nil)]
        let sources = try AudioSourceResolver.resolveSources(for: clip, missingExternal: .degradeToSilence)
        #expect(sources == [.stream(0), nil])
    }

    @Test func deadBookmarkThrowsForTheExport() {
        var clip = Clip(bookmark: Data(), displayName: "a.mp4")
        clip.audioTracks = [track()]
        clip.audioSelections = [.stream(0),
                                .external(bookmark: Data(), name: "gone.ac3",
                                          streamIndex: 0, tracks: nil, duration: nil)]
        #expect {
            try AudioSourceResolver.resolveSources(for: clip, missingExternal: .throwError)
        } throws: { error in
            error as? AudioSourceResolver.MissingExternalFile
                == AudioSourceResolver.MissingExternalFile(name: "gone.ac3", slot: 1)
        }
    }

    @Test func missingFileBehindALiveBookmarkCountsAsMissing() throws {
        // The bookmark resolves but the file was deleted since: same policy split.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vidconform-resolver-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("fleeting.mp3")
        try Data().write(to: file)
        let bookmark = try file.bookmarkData()
        try FileManager.default.removeItem(at: file)

        var clip = Clip(bookmark: Data(), displayName: "a.mp4")
        clip.audioTracks = [track()]
        clip.audioSelections = [.external(bookmark: bookmark, name: "fleeting.mp3",
                                          streamIndex: 0, tracks: nil, duration: nil)]
        #expect(try AudioSourceResolver.resolveSources(for: clip, missingExternal: .degradeToSilence)
                == [nil])
        #expect(throws: AudioSourceResolver.MissingExternalFile(name: "fleeting.mp3", slot: 0)) {
            try AudioSourceResolver.resolveSources(for: clip, missingExternal: .throwError)
        }
    }

    // MARK: output track derivation (ADR-0014)

    private func clipWithTracks(_ tracks: [AudioProperties]) -> Clip {
        var c = Clip(bookmark: Data(), displayName: "c")
        c.audio = tracks.first
        c.audioTracks = tracks
        return c
    }

    @Test func outputTrackCountIsTheRichestClips() {
        let a = AudioProperties(codec: "aac", sampleRate: 48000, channels: 2)
        let clips = [clipWithTracks([a]), clipWithTracks([a, a, a]), clipWithTracks([a, a])]
        let tracks = AudioSourceResolver.resolveOutputTracks(target: clips[0], clips: clips)
        #expect(tracks.count == 3)
    }

    @Test func trackFormatComesFromTheTargetFirstThenTimelineOrder() {
        let mono = AudioProperties(codec: "mp2", sampleRate: 44100, channels: 1, language: "eng", title: "Eurosport")
        let stereo = AudioProperties(codec: "aac", sampleRate: 48000, channels: 2, language: "spa", title: "TVE")
        let other = AudioProperties(codec: "ac3", sampleRate: 32000, channels: 2)
        // target carries one track; the second output track's spec falls to the first
        // clip in timeline order that has one.
        let target = clipWithTracks([mono])
        let clips = [clipWithTracks([other]), clipWithTracks([other, stereo])]
        let tracks = AudioSourceResolver.resolveOutputTracks(target: target, clips: clips)
        #expect(tracks == [
            AudioCodecPolicy.OutputAudioTrack(sampleRate: 44100, channels: 1, language: "eng", title: "Eurosport"),
            AudioCodecPolicy.OutputAudioTrack(sampleRate: 48000, channels: 2, language: "spa", title: "TVE"),
        ])
    }

    @Test func noAudioAnywhereResolvesToNoTracks() {
        let clips = [clipWithTracks([]), clipWithTracks([])]
        #expect(AudioSourceResolver.resolveOutputTracks(target: nil, clips: clips).isEmpty)
    }
}
