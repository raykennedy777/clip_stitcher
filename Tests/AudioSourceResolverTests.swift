import Testing
import Foundation
@testable import ClipStitcher

struct AudioSourceResolverTests {
    private func track(language: String? = nil, title: String? = nil) -> AudioProperties {
        AudioProperties(codec: "aac", sampleRate: 48000, channels: 2,
                        channelLayout: "stereo", language: language, title: title)
    }

    @Test func defaultSelectionResolvesToOwnStreamsInOrder() throws {
        var clip = Clip(bookmark: Data(), displayName: "multi.mkv")
        clip.audioTracks = [track(title: "A"), track(title: "B")]
        let sources = try AudioSourceResolver.resolveSources(for: clip, missingExternal: .throwError)
        #expect(sources == [.stream(0), .stream(1)])
    }

    @Test func outOfRangeOwnStreamIsSilenceUnderBothPolicies() throws {
        var clip = Clip(bookmark: Data(), displayName: "a.mp4")
        clip.audioTracks = [track()]
        clip.audioSelections = [.stream(0), .stream(7)]
        #expect(try AudioSourceResolver.resolveSources(for: clip, missingExternal: .degradeToSilence)
                == [.stream(0), nil])
        #expect(try AudioSourceResolver.resolveSources(for: clip, missingExternal: .throwError)
                == [.stream(0), nil])
    }

    @Test func externalFileResolvesToItsURLAndChosenStream() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-resolver-test-\(UUID().uuidString)")
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
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-resolver-test-\(UUID().uuidString)")
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
        let mono = AudioProperties(codec: "mp2", sampleRate: 44100, channels: 1, language: "eng", title: "Commentary")
        let stereo = AudioProperties(codec: "aac", sampleRate: 48000, channels: 2, language: "spa", title: "TVE")
        let other = AudioProperties(codec: "ac3", sampleRate: 32000, channels: 2)
        let target = clipWithTracks([mono])
        let clips = [clipWithTracks([other]), clipWithTracks([other, stereo])]
        let tracks = AudioSourceResolver.resolveOutputTracks(target: target, clips: clips)
        #expect(tracks == [
            AudioCodecPolicy.OutputAudioTrack(sampleRate: 44100, channels: 1, language: "eng", title: "Commentary"),
            AudioCodecPolicy.OutputAudioTrack(sampleRate: 48000, channels: 2, language: "spa", title: "TVE"),
        ])
    }

    @Test func noAudioAnywhereResolvesToNoTracks() {
        let clips = [clipWithTracks([]), clipWithTracks([])]
        #expect(AudioSourceResolver.resolveOutputTracks(target: nil, clips: clips).isEmpty)
    }

    private func ownTrack(codec: String, sampleRate: Int = 48000, channels: Int = 2,
                          language: String? = nil) -> AudioProperties {
        AudioProperties(codec: codec, sampleRate: sampleRate, channels: channels,
                        channelLayout: channels == 1 ? "mono" : "stereo",
                        language: language, title: nil)
    }

    private func clipOwning(_ tracks: [AudioProperties]) -> Clip {
        var clip = Clip(bookmark: Data(), displayName: "own.mkv")
        clip.audioTracks = tracks
        return clip
    }

    @Test func ownTracksCarryTheClipsOwnCountAndCodecs() {
        let clip = clipOwning([ownTrack(codec: "mp2", channels: 1, language: "fra"),
                               ownTrack(codec: "aac"), ownTrack(codec: "ac3")])
        let own = AudioSourceResolver.resolveOwnTracks(clip: clip, type: .videoAndAudio, container: .mkv)
        #expect(own.tracks.count == 3)
        #expect(own.tracks.map(\.encoder) == ["mp2", "aac", "ac3"])
        #expect(own.tracks[0].channels == 1)
        #expect(own.tracks[0].language == "fra")
        #expect(own.fallbacks.isEmpty)
    }

    @Test func aContainerInvalidCodecFallsBackToAACAtSourceLayout() {
        let clip = clipOwning([ownTrack(codec: "mp2", channels: 1), ownTrack(codec: "ac3")])
        let own = AudioSourceResolver.resolveOwnTracks(clip: clip, type: .videoAndAudio, container: .mp4)
        #expect(own.tracks.map(\.encoder) == ["aac", "ac3"])
        #expect(own.tracks[0].channels == 1)
        #expect(own.fallbacks.count == 1)
        #expect(own.fallbacks.first?.slot == 0)
        #expect(own.fallbacks.first?.codec == "mp2")
    }

    @Test func anUnmappableCodecFallsBackToAAC() {
        let clip = clipOwning([ownTrack(codec: "dts")])
        let own = AudioSourceResolver.resolveOwnTracks(clip: clip, type: .videoAndAudio, container: .mkv)
        #expect(own.tracks.map(\.encoder) == ["aac"])
        #expect(own.fallbacks.first?.codec == "dts")
    }

    @Test func audioOnlyKeepsOnlyTrackOne() {
        let clip = clipOwning([ownTrack(codec: "mp2"), ownTrack(codec: "ac3")])
        let own = AudioSourceResolver.resolveOwnTracks(clip: clip, type: .audioOnly, container: .mp4)
        #expect(own.tracks.count == 1)
        #expect(own.tracks.first?.encoder == "mp2")
        #expect(own.fallbacks.isEmpty)
    }

    @Test func aSilenceSlotGetsTheDefaultFormatAndNoFallback() {
        var clip = clipOwning([ownTrack(codec: "mp2", channels: 1)])
        clip.audioSelections = [.stream(0), .stream(5)]
        let own = AudioSourceResolver.resolveOwnTracks(clip: clip, type: .videoAndAudio, container: .ts)
        #expect(own.tracks.count == 2)
        #expect(own.tracks[1].sampleRate == 48000)
        #expect(own.tracks[1].channels == 2)
        #expect(own.fallbacks.isEmpty)
    }

    @Test func mixFiltersResolvePerSlotAgainstTheFeedingSource() {
        var clip = clipOwning([ownTrack(codec: "mp2", channels: 1),
                               ownTrack(codec: "aac", channels: 2)])
        clip.audioSelections = [
            AudioTrackSlot(selection: .stream(0), mix: .mono),
            AudioTrackSlot(selection: .stream(1), mix: .leftOnly),
            AudioTrackSlot(selection: .stream(1), mix: .original),
            AudioTrackSlot(selection: .stream(9), mix: .mono),
        ]
        let filters = AudioSourceResolver.resolveMixFilters(for: clip)
        #expect(filters.count == 4)
        #expect(filters[0] == nil)
        #expect(filters[1] == "pan=stereo|c0=c0|c1=c0")
        #expect(filters[2] == nil)
        #expect(filters[3] == nil)
    }

    @Test func externalSlotMixUsesItsProbedStreamChannels() {
        var clip = clipOwning([ownTrack(codec: "aac")])
        clip.audioSelections = [
            AudioTrackSlot(
                selection: .external(bookmark: Data(), name: "surround.mkv", streamIndex: 1,
                                     tracks: [ownTrack(codec: "aac", channels: 2),
                                              ownTrack(codec: "ac3", channels: 6)],
                                     duration: nil),
                mix: .stereo),
        ]
        let filters = AudioSourceResolver.resolveMixFilters(for: clip)
        #expect(filters == ["aformat=channel_layouts=stereo"])
    }
}
