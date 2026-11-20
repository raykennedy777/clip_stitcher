import Foundation
import Testing
@testable import ClipStitcher

struct PreviewAudioPlanTests {
    private let clipA = UUID()
    private let clipB = UUID()
    private let urlA = URL(fileURLWithPath: "/tmp/a.mpg")
    private let urlB = URL(fileURLWithPath: "/tmp/b.mkv")
    private let extURL = URL(fileURLWithPath: "/tmp/commentary.mp3")

    private func segments() -> [PreviewTimeline.Segment] {
        [
            PreviewTimeline.Segment(clipID: clipA, outputStart: 0, outputCount: 100,
                                    keptStart: 250, keptEnd: 349,
                                    windowStart: 10.24, conformed: false),
            PreviewTimeline.Segment(clipID: clipB, outputStart: 100, outputCount: 50,
                                    keptStart: 0, keptEnd: 49,
                                    windowStart: 0, conformed: false),
        ]
    }

    private let tracks = [
        AudioCodecPolicy.OutputAudioTrack(sampleRate: 48000, channels: 2,
                                          language: "eng", title: "World Feed"),
        AudioCodecPolicy.OutputAudioTrack(sampleRate: 44100, channels: 1),
    ]

    private func plan(sourcesA: [ExportEngine.AudioSource?],
                      sourcesB: [ExportEngine.AudioSource?],
                      mixFiltersA: [String?] = []) -> PreviewAudioPlan {
        PreviewAudioPlan.build(
            segments: segments(), targetFps: 25,
            clips: [
                clipA: PreviewAudioPlan.ClipAudio(url: urlA, containerStart: 0.24,
                                                  sources: sourcesA, mixFilters: mixFiltersA),
                clipB: PreviewAudioPlan.ClipAudio(url: urlB, containerStart: 0, sources: sourcesB),
            ],
            tracks: tracks)
    }

    @Test func ownStreamExternalAndSilenceLegsResolveLikeTheExport() {
        let p = plan(sourcesA: [.stream(0), .external(extURL, stream: 1)],
                     sourcesB: [.stream(2)])
        #expect(p.legs[0][0].source == .stream(urlA, streamIndex: 0))
        #expect(p.legs[0][1].source == .stream(urlB, streamIndex: 2))
        #expect(p.legs[1][0].source == .stream(extURL, streamIndex: 1))
        #expect(p.legs[1][1].source == .silence)
    }

    @Test func nilSourceIsSilence() {
        let p = plan(sourcesA: [nil], sourcesB: [.stream(0)])
        #expect(p.legs[0][0].source == .silence)
    }

    @Test func seekBaseSubtractsTheContainerStart() {
        let p = plan(sourcesA: [.stream(0)], sourcesB: [.stream(0)])
        #expect(abs(p.legs[0][0].seekBase - 10.0) < 1e-9)
        #expect(p.legs[0][1].seekBase == 0)
    }

    @Test func externalLegsShareTheClipsSeekBase() {
        let p = plan(sourcesA: [.external(extURL, stream: 0)], sourcesB: [.stream(0)])
        #expect(abs(p.legs[0][0].seekBase - 10.0) < 1e-9)
    }

    @Test func legTimingComesFromOutputFramesAtTheTargetRate() {
        let p = plan(sourcesA: [.stream(0)], sourcesB: [.stream(0)])
        #expect(p.legs[0][0].outputStart == 0)
        #expect(p.legs[0][0].duration == 4.0)
        #expect(p.legs[0][1].outputStart == 4.0)
        #expect(p.legs[0][1].duration == 2.0)
    }

    @Test func entryOffsetsTheSeekAndCapsTheDuration() {
        let p = plan(sourcesA: [.stream(0)], sourcesB: [.stream(0)])
        let mid = p.entry(track: 0, segment: 0, atOutputTime: 1.6)
        #expect(mid?.source == .stream(urlA, streamIndex: 0))
        #expect(abs((mid?.seekSeconds ?? -1) - 11.6) < 1e-9)
        #expect(abs((mid?.remaining ?? -1) - 2.4) < 1e-9)
        let join = p.entry(track: 0, segment: 1, atOutputTime: 4.0)
        #expect(join?.source == .stream(urlB, streamIndex: 0))
        #expect(join?.seekSeconds == 0)
        #expect(join?.remaining == 2.0)
    }

    @Test func entryRejectsOutOfRangeTrackOrSegment() {
        let p = plan(sourcesA: [.stream(0)], sourcesB: [.stream(0)])
        #expect(p.entry(track: 2, segment: 0, atOutputTime: 0) == nil)
        #expect(p.entry(track: 0, segment: 2, atOutputTime: 0) == nil)
        #expect(p.entry(track: -1, segment: 0, atOutputTime: 0) == nil)
    }

    @Test func conformFilterMatchesTheTracksFormat() {
        let p = plan(sourcesA: [.stream(0)], sourcesB: [.stream(0)])
        #expect(p.conformFilter(track: 0) == "aresample=48000,aformat=channel_layouts=stereo")
        #expect(p.conformFilter(track: 1) == "aresample=44100,aformat=channel_layouts=mono")
        #expect(p.conformFilter(track: 2) == nil)
    }

    @Test func legFilterPrependsTheClipsMixToTheConform() {
        let p = plan(sourcesA: [.stream(0)], sourcesB: [.stream(0)],
                     mixFiltersA: ["pan=stereo|c0=c0|c1=c0"])
        #expect(p.legFilter(track: 0, segment: 0)
            == "pan=stereo|c0=c0|c1=c0,aresample=48000,aformat=channel_layouts=stereo")
        #expect(p.legFilter(track: 0, segment: 1)
            == "aresample=48000,aformat=channel_layouts=stereo")
        #expect(p.legFilter(track: 2, segment: 0) == nil)
    }

    @Test func trackNamesFollowTheCutEditorNaming() {
        let p = plan(sourcesA: [.stream(0)], sourcesB: [.stream(0)])
        #expect(p.trackName(0) == "World Feed (eng)")
        #expect(p.trackName(1) == "Track 2")
    }
}
