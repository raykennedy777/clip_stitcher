import Foundation
import Testing
@testable import VidConform

/// Multi-track audio model rules (ADR-0014): track display naming from container
/// metadata with the "Track N" fallback, and project-JSON backward compatibility for
/// saves made before `audioTracks` existed.
struct AudioTrackModelTests {
    private func track(language: String? = nil, title: String? = nil) -> AudioProperties {
        AudioProperties(codec: "aac", sampleRate: 48000, channels: 2,
                        channelLayout: "stereo", language: language, title: title)
    }

    // MARK: - Display naming

    @Test func titleAndLanguageBothShown() {
        #expect(track(language: "eng", title: "World Feed").displayName(trackNumber: 2) == "World Feed (eng)")
    }

    @Test func titleAloneStandsByItself() {
        #expect(track(title: "Natural Sounds").displayName(trackNumber: 4) == "Natural Sounds")
    }

    @Test func languageAloneAppendsToTheFallback() {
        #expect(track(language: "spa").displayName(trackNumber: 3) == "Track 3 (spa)")
    }

    @Test func noMetadataFallsBackToTrackNumber() {
        #expect(track().displayName(trackNumber: 1) == "Track 1")
    }

    @Test func undeterminedLanguageIsNotShown() {
        // "und" is ffmpeg's explicit "no language" marker, not a name worth showing.
        #expect(track(language: "und").displayName(trackNumber: 1) == "Track 1")
    }

    @Test func emptyTagsCountAsAbsent() {
        #expect(track(language: "", title: "").displayName(trackNumber: 2) == "Track 2")
    }

    // MARK: - Save compatibility

    @Test func oldSaveWithoutAudioTracksFallsBackToTheSingleTrack() throws {
        var clip = Clip(bookmark: Data(), displayName: "old.mpg")
        clip.audio = track(language: "eng")
        clip.audioTracks = nil

        let decoded = try roundTrip(clip)
        #expect(decoded.audioTracks == nil)
        #expect(decoded.allAudioTracks == [track(language: "eng")])
    }

    @Test func preMultiTrackJSONDecodesWithNilAudioTracks() throws {
        // A literal pre-slice-9 clip payload: no audioTracks key, no language/title.
        let json = """
        {"id":"6F1E9A2B-1111-2222-3333-444455556666","bookmark":"","displayName":"a.mp4",
         "audio":{"codec":"mp2","sampleRate":48000,"channels":2}}
        """
        let decoded = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        #expect(decoded.audioTracks == nil)
        #expect(decoded.allAudioTracks.count == 1)
        #expect(decoded.allAudioTracks[0].codec == "mp2")
        #expect(decoded.allAudioTracks[0].language == nil)
    }

    @Test func probedTrackListSurvivesARoundTrip() throws {
        var clip = Clip(bookmark: Data(), displayName: "multi.mkv")
        clip.audio = track(language: "eng", title: "Eurosport")
        clip.audioTracks = [
            track(language: "eng", title: "Eurosport"),
            track(language: "spa", title: "TVE"),
            track(title: "Natural Sounds"),
        ]

        let decoded = try roundTrip(clip)
        #expect(decoded.allAudioTracks.count == 3)
        #expect(decoded.allAudioTracks[1].displayName(trackNumber: 2) == "TVE (spa)")
    }

    @Test func clipWithNoAudioHasNoTracks() {
        let clip = Clip(bookmark: Data(), displayName: "mute.mp4")
        #expect(clip.allAudioTracks.isEmpty)
    }

    private func roundTrip(_ clip: Clip) throws -> Clip {
        try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(clip))
    }

    // MARK: - Track selections (ADR-0014)

    @Test func defaultSelectionIsAllOwnStreamsInOrder() {
        var clip = Clip(bookmark: Data(), displayName: "multi.mkv")
        clip.audioTracks = [track(title: "A"), track(title: "B")]
        #expect(clip.resolvedAudioSelections == [.stream(0), .stream(1)])
        #expect(clip.effectiveAudioTracks.map { $0?.title } == ["A", "B"])
    }

    @Test func externalSelectionFeedsItsProbedProperties() {
        var clip = Clip(bookmark: Data(), displayName: "a.mp4")
        clip.audioTracks = [track(title: "Own")]
        clip.duration = 60
        clip.audioSelections = [
            .stream(0),
            .external(bookmark: Data(), name: "commentary.mp3", streamIndex: 0,
                      tracks: [track(language: "eng", title: "Commentary")], duration: 45),
        ]
        #expect(clip.effectiveAudioTracks[1]?.title == "Commentary")
        #expect(clip.audioTrackName(1) == "Commentary (eng)")
        // 45 s of audio against 60 s of video: 15 s short — silence fills, with a notice.
        #expect(clip.externalAudioMismatch(slot: 1) == -15)
        #expect(clip.externalAudioMismatch(slot: 0) == nil)
    }

    @Test func externalSelectionPicksAmongTheFilesStreams() {
        // demo.mkv carries two audio streams; the slot points at its second one.
        var clip = Clip(bookmark: Data(), displayName: "a.mp4")
        clip.audioTracks = [track(title: "Own")]
        clip.audioSelections = [
            .external(bookmark: Data(), name: "demo.mkv", streamIndex: 1,
                      tracks: [track(language: "eng", title: "World Feed"),
                               track(language: "spa", title: "TVE")],
                      duration: nil),
        ]
        #expect(clip.effectiveAudioTracks[0]?.title == "TVE")
        #expect(clip.audioTrackName(0) == "TVE (spa)")
    }

    @Test func outOfRangeStreamSelectionNamesTheFallback() {
        var clip = Clip(bookmark: Data(), displayName: "a.mp4")
        clip.audioTracks = [track(title: "Own")]
        clip.audioSelections = [.stream(0), .stream(7)]
        #expect(clip.effectiveAudioTracks[1] == nil)
        #expect(clip.audioTrackName(1) == "Track 2")
    }

    @Test func selectionsSurviveARoundTrip() throws {
        var clip = Clip(bookmark: Data(), displayName: "a.mkv")
        clip.audioTracks = [track(title: "A")]
        clip.audioSelections = [.external(bookmark: Data([1, 2]), name: "x.ac3", streamIndex: 0,
                                          tracks: [track()], duration: 9.5)]
        clip.monitoredAudioTrack = 0
        let decoded = try roundTrip(clip)
        #expect(decoded.audioSelections == clip.audioSelections)
        #expect(decoded.monitoredAudioTrack == 0)
    }

    @Test func selectionsDriveTheOutputTrackCount() {
        let a = AudioProperties(codec: "aac", sampleRate: 48000, channels: 2)
        var rich = Clip(bookmark: Data(), displayName: "r")
        rich.audioTracks = [a]
        // one own stream, but three selected slots (the third is an external file)
        rich.audioSelections = [.stream(0), .stream(0),
                                .external(bookmark: Data(), name: "x.mp3", streamIndex: 0,
                                          tracks: [a], duration: nil)]
        var plain = Clip(bookmark: Data(), displayName: "p")
        plain.audioTracks = [a]
        let tracks = AudioCodecPolicy.resolveOutputTracks(target: plain, clips: [plain, rich])
        #expect(tracks.count == 3)
    }
}
