import Testing
@testable import ClipStitcher

/// The pure halves of the scene-change jump (ROADMAP slice 8): parsing ffmpeg's
/// `metadata=print` output, mapping times back to frames, and the landing rules —
/// first cut forward / last cut backward, give up and land at the cap/floor when
/// the 5-second window holds none.
struct SceneScanLandingTests {
    @Test func forwardLandsOnTheFirstSceneChangeAfterTheCurrentFrame() {
        #expect(SceneScan.forwardLanding(sceneFrames: [120, 180], current: 100, cap: 225) == 120)
    }

    @Test func forwardIgnoresGuardFramesAtOrBeforeTheCurrentFrame() {
        // The decode lead-in can report scene changes before the playhead — never
        // a forward landing.
        #expect(SceneScan.forwardLanding(sceneFrames: [80, 100, 150], current: 100, cap: 225) == 150)
    }

    @Test func forwardLandsAtTheCapWhenTheWindowHoldsNoSceneChange() {
        #expect(SceneScan.forwardLanding(sceneFrames: [], current: 100, cap: 225) == 225)
    }

    @Test func forwardIgnoresSceneChangesBeyondTheCap() {
        // Slop decode past the window can report a cut past the cap — give up at
        // the cap instead of overshooting the 5-second promise.
        #expect(SceneScan.forwardLanding(sceneFrames: [240], current: 100, cap: 225) == 225)
    }

    @Test func backwardLandsOnTheLastSceneChangeBeforeTheCurrentFrame() {
        #expect(SceneScan.backwardLanding(sceneFrames: [20, 60], current: 100, floor: 0) == 60)
    }

    @Test func backwardIgnoresTheCurrentFrameAndLater() {
        #expect(SceneScan.backwardLanding(sceneFrames: [60, 100, 110], current: 100, floor: 0) == 60)
    }

    @Test func backwardLandsAtTheFloorWhenTheWindowHoldsNoSceneChange() {
        #expect(SceneScan.backwardLanding(sceneFrames: [], current: 100, floor: 0) == 0)
    }

    @Test func backwardIgnoresSceneChangesBeforeTheFloor() {
        // Guard frames decode before the window floor; landing there would jump
        // further back than the 5-second promise.
        #expect(SceneScan.backwardLanding(sceneFrames: [3], current: 130, floor: 5) == 5)
    }
}

struct SceneScanParsingTests {
    @Test func parsesPTSTimesFromMetadataPrintOutput() {
        let output = """
        frame:0    pts:162082800 pts_time:14.32
        lavfi.scene_score=0.291898
        frame:1    pts:162086400 pts_time:16.68
        lavfi.scene_score=0.449863
        """
        #expect(SceneScan.parsePTSTimes(output) == [14.32, 16.68])
    }

    @Test func parsingIgnoresUnrelatedLines() {
        #expect(SceneScan.parsePTSTimes("lavfi.scene_score=0.5\n\n").isEmpty)
    }

    @Test func scanReportsAbsoluteTimestamps() {
        // -copyts keeps reported pts_time absolute. Without it ffmpeg re-zeroes
        // against the *container* start time, which differs from the video
        // stream's start when audio leads video (the H.264 clip: 0.0 vs 0.04) —
        // that one-frame skew made every scene jump land one frame late.
        let args = SceneScan.arguments(inputPath: "x", seekStart: 0, duration: 5, deinterlace: false)
        #expect(args.contains("-copyts"))
    }

    @Test func deinterlacePrependsYadifToTheScanFilter() {
        let interlaced = SceneScan.arguments(inputPath: "x", seekStart: 0, duration: 5, deinterlace: true)
        let progressive = SceneScan.arguments(inputPath: "x", seekStart: 0, duration: 5, deinterlace: false)
        #expect(interlaced.contains { $0.hasPrefix("yadif=0,select=") })
        #expect(!progressive.contains { $0.hasPrefix("yadif") })
    }
}

struct SceneScanNearestFrameTests {
    private let pts = [0.24, 0.28, 0.32, 0.36, 0.40]

    @Test func exactMatchReturnsThatFrame() {
        #expect(SceneScan.nearestFrame(toPTS: 0.32, in: pts) == 2)
    }

    @Test func midpointTimesRoundToTheNearerFrame() {
        #expect(SceneScan.nearestFrame(toPTS: 0.295, in: pts) == 1)
        #expect(SceneScan.nearestFrame(toPTS: 0.305, in: pts) == 2)
    }

    @Test func timesOutsideTheRangeClampToTheEnds() {
        #expect(SceneScan.nearestFrame(toPTS: 0.0, in: pts) == 0)
        #expect(SceneScan.nearestFrame(toPTS: 9.9, in: pts) == 4)
    }
}
