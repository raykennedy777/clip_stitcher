import Foundation
import Testing
@testable import ClipStitcher

/// The pure audio side of the output preview (issue #8): per-(track × segment) leg
/// resolution mirroring the export's audio rebuild (ADR-0014), and the seek/duration
/// math for joining a leg mid-stream. The streaming side is verified at runtime
/// (subprocess-spawning tests hang the test runner).
struct PreviewAudioPlanTests {
    private let clipA = UUID()
    private let clipB = UUID()
    private let urlA = URL(fileURLWithPath: "/tmp/a.mpg")
    private let urlB = URL(fileURLWithPath: "/tmp/b.mkv")
    private let extURL = URL(fileURLWithPath: "/tmp/commentary.mp3")

    /// Two segments at 25 fps: clip A frames 0–99 (kept window starts at pts 10.24,
    /// container start 0.24 — the MPEG-PS shape), clip B frames 100–149 (open in
    /// point: windowStart 0).
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
        // Track 1: both clips feed it from their own file.
        #expect(p.legs[0][0].source == .stream(urlA, streamIndex: 0))
        #expect(p.legs[0][1].source == .stream(urlB, streamIndex: 2))
        // Track 2: clip A re-points it at an external file; clip B has no source
        // for it — silence, exactly the export's anullsrc leg.
        #expect(p.legs[1][0].source == .stream(extURL, streamIndex: 1))
        #expect(p.legs[1][1].source == .silence)
    }

    /// The export maps a selection past the clip's own streams to silence
    /// (ProjectDocument builds `nil` there); the plan receives that nil unchanged.
    @Test func nilSourceIsSilence() {
        let p = plan(sourcesA: [nil], sourcesB: [.stream(0)])
        #expect(p.legs[0][0].source == .silence)
    }

    /// The seek base is the kept window's start as input-seek seconds — `pts −
    /// container start_time` (the ADR-0013/0015 trap), and 0 for an open in point
    /// even on a non-zero-start container (the export omits `-ss` there).
    @Test func seekBaseSubtractsTheContainerStart() {
        let p = plan(sourcesA: [.stream(0)], sourcesB: [.stream(0)])
        #expect(abs(p.legs[0][0].seekBase - 10.0) < 1e-9)
        #expect(p.legs[0][1].seekBase == 0)
    }

    /// An external file gets the same seek value as the clip's own streams: its
    /// timeline starts at the video file's start (ADR-0014) and `-ss` into it is
    /// file-start-relative (measured — ADR-0015).
    @Test func externalLegsShareTheClipsSeekBase() {
        let p = plan(sourcesA: [.external(extURL, stream: 0)], sourcesB: [.stream(0)])
        #expect(abs(p.legs[0][0].seekBase - 10.0) < 1e-9)
    }

    @Test func legTimingComesFromOutputFramesAtTheTargetRate() {
        let p = plan(sourcesA: [.stream(0)], sourcesB: [.stream(0)])
        #expect(p.legs[0][0].outputStart == 0)
        #expect(p.legs[0][0].duration == 4.0)     // 100 frames at 25 fps
        #expect(p.legs[0][1].outputStart == 4.0)  // 50 frames at 25 fps
        #expect(p.legs[0][1].duration == 2.0)
    }

    /// Joining a leg mid-stream: the spawn seeks `seekBase` plus the time already
    /// elapsed inside the leg, and is capped to what remains — so a leg can never
    /// play past its clip's out point, even if the join restart runs late.
    @Test func entryOffsetsTheSeekAndCapsTheDuration() {
        let p = plan(sourcesA: [.stream(0)], sourcesB: [.stream(0)])
        // 1.6 s into the timeline = 1.6 s into clip A's leg.
        let mid = p.entry(track: 0, segment: 0, atOutputTime: 1.6)
        #expect(mid?.source == .stream(urlA, streamIndex: 0))
        #expect(abs((mid?.seekSeconds ?? -1) - 11.6) < 1e-9)
        #expect(abs((mid?.remaining ?? -1) - 2.4) < 1e-9)
        // Exactly at the join: clip B's leg from its start.
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

    /// Every leg is conformed to its output track's rate/layout — the same filter
    /// the export puts on every leg of that track's chain (ADR-0014), so the
    /// preview sounds like the export.
    @Test func conformFilterMatchesTheTracksFormat() {
        let p = plan(sourcesA: [.stream(0)], sourcesB: [.stream(0)])
        #expect(p.conformFilter(track: 0) == "aresample=48000,aformat=channel_layouts=stereo")
        #expect(p.conformFilter(track: 1) == "aresample=44100,aformat=channel_layouts=mono")
        #expect(p.conformFilter(track: 2) == nil)
    }

    /// A leg's channel mix (ADR-0019) composes before the track conform — the same
    /// order as the export's rebuild chain — and only on the clip that set it; a
    /// mix-free leg falls back to the bare conform.
    @Test func legFilterPrependsTheClipsMixToTheConform() {
        let p = plan(sourcesA: [.stream(0)], sourcesB: [.stream(0)],
                     mixFiltersA: ["pan=stereo|c0=c0|c1=c0"])
        #expect(p.legFilter(track: 0, segment: 0)
            == "pan=stereo|c0=c0|c1=c0,aresample=48000,aformat=channel_layouts=stereo")
        #expect(p.legFilter(track: 0, segment: 1)
            == "aresample=48000,aformat=channel_layouts=stereo")
        // Out-of-range gracefully degrades like conformFilter.
        #expect(p.legFilter(track: 2, segment: 0) == nil)
    }

    /// Picker rows are named like the cut-editor dropdown: container title when
    /// present, else "Track N", with the language tag appended.
    @Test func trackNamesFollowTheCutEditorNaming() {
        let p = plan(sourcesA: [.stream(0)], sourcesB: [.stream(0)])
        #expect(p.trackName(0) == "World Feed (eng)")
        #expect(p.trackName(1) == "Track 2")
    }
}

/// Preview audio's spawn commands (issue #8): the per-leg conform filter, the leg
/// duration cap, and the silence leg — shapes de-risked in the shell on all three
/// formats + the 4-track MKV (exact byte counts, first byte in 13–23 ms).
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

/// The preview's track choice persists per project (pinned #8 decision): a new
/// optional field on the project model — old saves decode to the default, track 1.
struct MonitoredOutputTrackPersistenceTests {
    @Test func oldSavesDecodeToNilMeaningTrackOne() throws {
        let json = #"{"clips":[],"output":{"mode":"connect","type":"videoAndAudio","container":"ts"}}"#
        let project = try JSONDecoder().decode(VidProject.self, from: Data(json.utf8))
        #expect(project.monitoredOutputTrack == nil)
    }

    @Test func trackChoiceRoundTrips() throws {
        var project = VidProject()
        project.monitoredOutputTrack = 2
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(VidProject.self, from: data)
        #expect(decoded.monitoredOutputTrack == 2)
    }
}
