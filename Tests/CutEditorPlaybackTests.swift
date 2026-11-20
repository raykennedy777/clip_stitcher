import Testing
@testable import ClipStitcher

struct PlaybackEndTests {
    @Test func sessionStartedBeforeTheOutPointStopsThere() {
        #expect(CutEditorModel.playbackEnd(outPoint: 100, origin: 50, lastFrame: 500) == 100)
    }

    @Test func sessionStartedAtOrPastTheOutPointRunsToTheClipEnd() {
        #expect(CutEditorModel.playbackEnd(outPoint: 100, origin: 100, lastFrame: 500) == 500)
        #expect(CutEditorModel.playbackEnd(outPoint: 100, origin: 200, lastFrame: 500) == 500)
    }

    @Test func noOutPointRunsToTheClipEnd() {
        #expect(CutEditorModel.playbackEnd(outPoint: nil, origin: 0, lastFrame: 500) == 500)
    }

    @Test func outPointBeyondTheIndexIsClampedToTheLastFrame() {
        #expect(CutEditorModel.playbackEnd(outPoint: 600, origin: 0, lastFrame: 500) == 500)
    }
}
