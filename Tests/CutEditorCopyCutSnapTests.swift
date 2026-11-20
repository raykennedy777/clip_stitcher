import Testing
import Foundation
@testable import ClipStitcher

@MainActor
struct CutEditorCopyCutSnapTests {
    private let openGopCounts: [Int?] = [0, nil, nil, nil, 2, nil, nil, nil,
                                         0, nil, nil, nil, 2, nil, nil, nil]

    private func makeClip(fieldCoded: Bool?, codec: String = "h264") -> Clip {
        var clip = Clip(bookmark: Data(), displayName: "clip.ts")
        clip.video = VideoProperties(codec: codec, width: 720, height: 480,
                                     frameRate: "25/1", pixelFormat: "yuv420p")
        clip.fieldCoded = fieldCoded
        return clip
    }

    private func makeModel(fieldCoded: Bool?, codec: String = "h264") -> CutEditorModel {
        CutEditorModel(
            clip: makeClip(fieldCoded: fieldCoded, codec: codec),
            url: URL(fileURLWithPath: "/tmp/clip.ts"), document: ProjectDocument())
    }

    @Test func inPointSnapsToACountZeroKeyframeAndMovesThePlayhead() {
        let model = makeModel(fieldCoded: true)
        model.primeForTesting(frameCount: openGopCounts.count, leadingCounts: openGopCounts)
        model.currentFrame = 6

        model.setIn()

        #expect(model.inPoint == 8)
        #expect(model.currentFrame == 8)
    }

    @Test func outPointSnapsToKeyframeMinusLeadingCountAndMovesThePlayhead() {
        let model = makeModel(fieldCoded: true)
        model.primeForTesting(frameCount: openGopCounts.count, leadingCounts: openGopCounts)
        model.currentFrame = 3

        model.setOut()

        #expect(model.outPoint == 1)
        #expect(model.currentFrame == 1)
    }

    @Test func outPointSnappedToTheLastFrameClearsToNilButStillMovesThePlayhead() {
        let model = makeModel(fieldCoded: true)
        let counts: [Int?] = [0, nil, nil, nil, 0]
        model.primeForTesting(frameCount: 4, leadingCounts: counts)
        model.currentFrame = 1

        model.setOut()

        #expect(model.outPoint == nil)
        #expect(model.currentFrame == 3)
    }

    @Test func inPointIsANoOpWhenNoCopySafeKeyframeExists() {
        let model = makeModel(fieldCoded: true)
        model.primeForTesting(frameCount: 3, leadingCounts: [nil, 2, nil])
        model.currentFrame = 1
        model.inPoint = 3

        model.setIn()

        #expect(model.inPoint == 3)
        #expect(model.currentFrame == 1)
    }

    @Test func outPointIsANonDestructiveNoOpWhenNoCandidateExists() {
        let model = makeModel(fieldCoded: true)
        model.primeForTesting(frameCount: 3, leadingCounts: [nil, 2, nil])
        model.currentFrame = 1
        model.outPoint = 2

        model.setOut()

        #expect(model.outPoint == 2)
        #expect(model.currentFrame == 1)
    }

    @Test func marksAreNonDestructiveNoOpsBeforeTheIndexIsPrimed() {
        let model = makeModel(fieldCoded: true)

        model.inPoint = 4
        model.outPoint = 9
        model.setIn()
        model.setOut()

        #expect(model.inPoint == 4)
        #expect(model.outPoint == 9)
    }

    @Test func inPointConflictRuleUsesTheSnappedValueNotTheRawRequest() {
        let model = makeModel(fieldCoded: true)
        model.primeForTesting(frameCount: openGopCounts.count, leadingCounts: openGopCounts)
        model.outPoint = 7
        model.currentFrame = 6

        model.setIn()

        #expect(model.inPoint == 8)
        #expect(model.outPoint == nil)
        #expect(model.currentFrame == 8)
    }

    @Test func outPointConflictRuleUsesTheSnappedValueNotTheRawRequest() {
        let model = makeModel(fieldCoded: true)
        model.primeForTesting(frameCount: openGopCounts.count, leadingCounts: openGopCounts)
        model.inPoint = 9
        model.currentFrame = 8

        model.setOut()

        #expect(model.outPoint == 9)
        #expect(model.inPoint == 9)
        #expect(model.currentFrame == 9)
    }

    @Test func toggleSplitSnapsToACopySafeKeyframeAndMovesThePlayhead() {
        let model = makeModel(fieldCoded: true)
        model.primeForTesting(frameCount: openGopCounts.count, leadingCounts: openGopCounts)
        model.currentFrame = 6

        model.toggleSplit()

        #expect(model.splitPoints == [8])
        #expect(model.currentFrame == 8)
    }

    @Test func toggleSplitFromAnUnsnappedNearbyFrameRemovesTheExistingSnappedSplit() {
        let model = makeModel(fieldCoded: true)
        model.primeForTesting(frameCount: openGopCounts.count, leadingCounts: openGopCounts)
        model.splitPoints = [8]
        model.currentFrame = 7

        model.toggleSplit()

        #expect(model.splitPoints.isEmpty)
        #expect(model.currentFrame == 8)
    }

    @Test func toggleSplitIsANoOpWhenNoCopySafeKeyframeExists() {
        let model = makeModel(fieldCoded: true)
        model.primeForTesting(frameCount: 3, leadingCounts: [nil, 2, nil])
        model.currentFrame = 1

        model.toggleSplit()

        #expect(model.splitPoints.isEmpty)
        #expect(model.currentFrame == 1)
    }

    @Test func progressiveClipSplitsAtTheRawFrameExactly() {
        let model = makeModel(fieldCoded: false)
        model.primeForTesting(frameCount: openGopCounts.count, leadingCounts: openGopCounts)
        model.currentFrame = 6

        model.toggleSplit()

        #expect(model.splitPoints == [6])
        #expect(model.currentFrame == 6)
    }

    @Test func progressiveClipTakesTheRawFrameExactly() {
        let model = makeModel(fieldCoded: false)
        model.primeForTesting(frameCount: openGopCounts.count, leadingCounts: openGopCounts)
        model.outPoint = 5
        model.currentFrame = 6

        model.setIn()

        #expect(model.inPoint == 6)
        #expect(model.outPoint == nil)
        #expect(model.currentFrame == 6)
    }

    @Test func fieldCodedNilDoesNotSnap() {
        let model = makeModel(fieldCoded: nil)
        model.primeForTesting(frameCount: openGopCounts.count, leadingCounts: openGopCounts)
        model.currentFrame = 6

        model.setIn()

        #expect(model.inPoint == 6)
        #expect(model.currentFrame == 6)
    }

    @Test func nonH264FieldCodedCodecDoesNotSnap() {
        let model = makeModel(fieldCoded: true, codec: "hevc")
        model.primeForTesting(frameCount: openGopCounts.count, leadingCounts: openGopCounts)
        model.currentFrame = 6

        model.setOut()

        #expect(model.outPoint == 6)
        #expect(model.currentFrame == 6)
    }
}
