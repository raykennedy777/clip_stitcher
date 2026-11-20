import Foundation
import Testing
@testable import ClipStitcher

struct AudioTrackModelTests {
    private func track(language: String? = nil, title: String? = nil) -> AudioProperties {
        AudioProperties(codec: "aac", sampleRate: 48000, channels: 2,
                        channelLayout: "stereo", language: language, title: title)
    }

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
        #expect(track(language: "und").displayName(trackNumber: 1) == "Track 1")
    }

    @Test func emptyTagsCountAsAbsent() {
        #expect(track(language: "", title: "").displayName(trackNumber: 2) == "Track 2")
    }

    @Test func oldSaveWithoutAudioTracksFallsBackToTheSingleTrack() throws {
        var clip = Clip(bookmark: Data(), displayName: "old.mpg")
        clip.audio = track(language: "eng")
        clip.audioTracks = nil

        let decoded = try roundTrip(clip)
        #expect(decoded.audioTracks == nil)
        #expect(decoded.allAudioTracks == [track(language: "eng")])
    }

    @Test func preMultiTrackJSONDecodesWithNilAudioTracks() throws {
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
        clip.audio = track(language: "eng", title: "Commentary")
        clip.audioTracks = [
            track(language: "eng", title: "Commentary"),
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
        #expect(clip.externalAudioMismatch(slot: 1) == -15)
        #expect(clip.externalAudioMismatch(slot: 0) == nil)
    }

    @Test func externalSelectionPicksAmongTheFilesStreams() {
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

    @Test func noOpTableMatchesTheADR() {
        #expect(ChannelMix.stereo.isNoOp(sourceChannels: 1))
        #expect(ChannelMix.stereo.isNoOp(sourceChannels: 2))
        #expect(!ChannelMix.stereo.isNoOp(sourceChannels: 6))
        for mix in [ChannelMix.leftOnly, .rightOnly, .mono] {
            #expect(mix.isNoOp(sourceChannels: 1))
            #expect(!mix.isNoOp(sourceChannels: 2))
            #expect(!mix.isNoOp(sourceChannels: 6))
        }
        #expect(ChannelMix.original.isNoOp(sourceChannels: 6))
        for mix in ChannelMix.allCases {
            #expect(mix.isNoOp(sourceChannels: nil))
        }
    }

    @Test func defaultSlotsCarryTheOriginalMix() {
        var clip = Clip(bookmark: Data(), displayName: "a.mkv")
        clip.audioTracks = [track(), track()]
        #expect(clip.resolvedAudioSelections.allSatisfy { $0.mix == .original })
    }

    @Test func preMixSlotJSONDecodesWithOriginalEverywhere() throws {
        let json = """
        {"id":"6F1E9A2B-1111-2222-3333-444455556666","bookmark":"","displayName":"a.mkv",
         "audioSelections":[{"stream":{"_0":1}},
            {"external":{"bookmark":"","name":"x.mp3","streamIndex":0}}]}
        """
        let decoded = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        let slots = try #require(decoded.audioSelections)
        #expect(slots.count == 2)
        #expect(slots[0] == .stream(1))
        #expect(slots.allSatisfy { $0.mix == .original })
        if case .external(_, let name, _, _, _) = slots[1].selection {
            #expect(name == "x.mp3")
        } else {
            Issue.record("second slot should still decode as the external selection")
        }
    }

    @Test func mixSurvivesARoundTrip() throws {
        var clip = Clip(bookmark: Data(), displayName: "a.mkv")
        clip.audioTracks = [track(), track()]
        clip.audioSelections = [AudioTrackSlot(selection: .stream(0), mix: .leftOnly),
                                .stream(1)]
        let decoded = try roundTrip(clip)
        #expect(decoded.audioSelections?[0].mix == .leftOnly)
        #expect(decoded.audioSelections?[1].mix == .original)
    }

    @Test func selectionsDriveTheOutputTrackCount() {
        let a = AudioProperties(codec: "aac", sampleRate: 48000, channels: 2)
        var rich = Clip(bookmark: Data(), displayName: "r")
        rich.audioTracks = [a]
        rich.audioSelections = [.stream(0), .stream(0),
                                .external(bookmark: Data(), name: "x.mp3", streamIndex: 0,
                                          tracks: [a], duration: nil)]
        var plain = Clip(bookmark: Data(), displayName: "p")
        plain.audioTracks = [a]
        let tracks = AudioSourceResolver.resolveOutputTracks(target: plain, clips: [plain, rich])
        #expect(tracks.count == 3)
    }
}
