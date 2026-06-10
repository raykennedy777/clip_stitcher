import Testing
@testable import VidConform

/// Where a play session stops (the QA finding on issue #7's verification pass:
/// pressing Play at or past the out point looked like a dead button, because the
/// loop stopped on its first tick). The rule: the out point ends a session that
/// started before it; a session starting at or past it runs to the clip end.
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
