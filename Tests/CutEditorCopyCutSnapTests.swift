import Testing
import Foundation
@testable import ClipStitcher

/// Exercises `CutEditorModel.setIn`/`setOut`'s copy-cut snapping (issue #96): a
/// field-coded H.264 clip's marks route through `CopyCutSnapper` before the existing
/// in/out conflict rule, and the playhead follows the snap so the marker visibly lands
/// where the cut will happen. Every other clip shape (progressive, still-probing
/// `fieldCoded == nil`, or a field-coded codec the copy-cut route doesn't cover) takes
/// the raw playhead frame exactly as before #96.
///
/// Uses `CutEditorModel.primeForTesting` (a `#if DEBUG` seam) to install a frame count
/// and leading-picture-count shape directly, standing in for `load()`'s real ffprobe
/// pass — the model never spawns ffmpeg here.
@MainActor
struct CutEditorCopyCutSnapTests {
    /// The 16-frame open-GOP shape from `CopyCutSnapperTests`: copy-safe (count 0)
    /// keyframes at 0 and 8; open (count 2) keyframes at 4 and 12. In-point candidates
    /// {0, 8}; out-point candidates {1, 7, 9} (4→1, 8→7, 12→9 — the file-start keyframe
    /// at 0 ends nothing).
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

    // MARK: - Field-coded H.264: snapping active

    /// A requested in-point snaps to the nearest count-0 keyframe, and the playhead
    /// follows it there.
    @Test func inPointSnapsToACountZeroKeyframeAndMovesThePlayhead() {
        let model = makeModel(fieldCoded: true)
        model.primeForTesting(frameCount: openGopCounts.count, leadingCounts: openGopCounts)
        model.currentFrame = 6

        model.setIn()

        #expect(model.inPoint == 8)      // nearest count-0 keyframe to 6
        #expect(model.currentFrame == 8) // playhead followed the mark
    }

    /// A requested out-point snaps to `k − count − 1` for the nearest counted keyframe,
    /// and the playhead follows it.
    @Test func outPointSnapsToKeyframeMinusLeadingCountAndMovesThePlayhead() {
        let model = makeModel(fieldCoded: true)
        model.primeForTesting(frameCount: openGopCounts.count, leadingCounts: openGopCounts)
        model.currentFrame = 3

        model.setOut()

        #expect(model.outPoint == 1)     // keyframe 4, count 2 → 4−2−1 = 1
        #expect(model.currentFrame == 1)
    }

    /// A snapped out-point landing exactly on the clip's last frame prefers `nil` (open
    /// clip end = copy to EOF) over the explicit index, so the planner's no-cut
    /// copy-to-EOF treatment still applies — an explicit last-frame out would instead
    /// force a needless tail re-encode. `leadingCounts` here is longer than
    /// `frameCount`, a shape `CopySafeBoundaryDetector` itself never produces (its
    /// `k − count − 1` formula tops out one frame short of the real last frame) — it
    /// pins down `setOut`'s own defensive clamp in isolation, independent of whether
    /// the detector could ever hand it this input. The playhead still follows the
    /// snapped boundary even though the stored point ends up nil.
    @Test func outPointSnappedToTheLastFrameClearsToNilButStillMovesThePlayhead() {
        let model = makeModel(fieldCoded: true)
        let counts: [Int?] = [0, nil, nil, nil, 0] // k=4, count 0 → lastKept = 3 = lastFrame
        model.primeForTesting(frameCount: 4, leadingCounts: counts)
        model.currentFrame = 1

        model.setOut()

        #expect(model.outPoint == nil)
        #expect(model.currentFrame == 3)
    }

    /// No copy-safe keyframe exists anywhere (only an open one) — `snapInPoint` returns
    /// nil, and the mark is a no-op: state and playhead stay exactly as they were.
    @Test func inPointIsANoOpWhenNoCopySafeKeyframeExists() {
        let model = makeModel(fieldCoded: true)
        model.primeForTesting(frameCount: 3, leadingCounts: [nil, 2, nil])
        model.currentFrame = 1
        model.inPoint = 3 // a sentinel pre-existing value the no-op must not disturb

        model.setIn()

        #expect(model.inPoint == 3)
        #expect(model.currentFrame == 1)
    }

    /// No out candidate exists anywhere (the only counted keyframe's `k − count − 1` is
    /// negative) — `snapOutPoint` returns nil, and the mark must be a **non-destructive**
    /// no-op: a previously stored out point survives. (The regression: this branch used
    /// to wipe it to nil.)
    @Test func outPointIsANonDestructiveNoOpWhenNoCandidateExists() {
        let model = makeModel(fieldCoded: true)
        model.primeForTesting(frameCount: 3, leadingCounts: [nil, 2, nil]) // k=1 → 1−2−1 < 0
        model.currentFrame = 1
        model.outPoint = 2 // a sentinel pre-existing value the no-op must not disturb

        model.setOut()

        #expect(model.outPoint == 2)
        #expect(model.currentFrame == 1)
    }

    /// Before the index is primed (`leadingCounts` still empty — marks pressed while the
    /// clip is still indexing) neither mark may act, and neither may wipe existing points.
    @Test func marksAreNonDestructiveNoOpsBeforeTheIndexIsPrimed() {
        let model = makeModel(fieldCoded: true) // never primed

        model.inPoint = 4
        model.outPoint = 9
        model.setIn()
        model.setOut()

        #expect(model.inPoint == 4)
        #expect(model.outPoint == 9)
    }

    /// Snapping applies the in/out conflict rule to the *snapped* value, not the raw
    /// requested frame — order matters. Requesting an in-point at frame 6 snaps to 8
    /// (the nearer count-0 keyframe); an existing out-point of 7 sits strictly between
    /// the raw request and the snapped value, so only checking the snapped value (8)
    /// against it clears it — checking the raw request (6) would not have.
    @Test func inPointConflictRuleUsesTheSnappedValueNotTheRawRequest() {
        let model = makeModel(fieldCoded: true)
        model.primeForTesting(frameCount: openGopCounts.count, leadingCounts: openGopCounts)
        model.outPoint = 7
        model.currentFrame = 6

        model.setIn()

        #expect(model.inPoint == 8)
        #expect(model.outPoint == nil) // 7 < 8 (the snapped in), so it's cleared
        #expect(model.currentFrame == 8)
    }

    /// Same as above, mirrored for `setOut`: a raw request of 8 ties between out
    /// candidates 7 and 9, breaking to the later (9, per `CopyCutSnapper`'s "keep the
    /// requested frame inside the range" tie rule). An existing in-point of 9 does not
    /// conflict with the snapped 9 (equal, not strictly after) — checking the raw
    /// request (8) instead would have wrongly cleared it (9 > 8).
    @Test func outPointConflictRuleUsesTheSnappedValueNotTheRawRequest() {
        let model = makeModel(fieldCoded: true)
        model.primeForTesting(frameCount: openGopCounts.count, leadingCounts: openGopCounts)
        model.inPoint = 9
        model.currentFrame = 8

        model.setOut()

        #expect(model.outPoint == 9)
        #expect(model.inPoint == 9) // unchanged — the snapped 9 doesn't conflict with itself
        #expect(model.currentFrame == 9)
    }

    // MARK: - Split points route through the same snapping (issue #96 regression:
    // toggleSplit inserted the raw playhead frame, so a mid-GOP split reached the
    // planner unsnapped and threw at export)

    /// A split on a copy-cut clip lands snapped on the nearest copy-safe keyframe —
    /// valid for both resulting pieces — and the playhead follows it like `setIn`.
    @Test func toggleSplitSnapsToACopySafeKeyframeAndMovesThePlayhead() {
        let model = makeModel(fieldCoded: true)
        model.primeForTesting(frameCount: openGopCounts.count, leadingCounts: openGopCounts)
        model.currentFrame = 6

        model.toggleSplit()

        #expect(model.splitPoints == [8])
        #expect(model.currentFrame == 8)
    }

    /// Toggle-off operates on the *snapped* frame: pressing split while parked mid-GOP
    /// near an existing snapped split removes it instead of stacking a second point.
    @Test func toggleSplitFromAnUnsnappedNearbyFrameRemovesTheExistingSnappedSplit() {
        let model = makeModel(fieldCoded: true)
        model.primeForTesting(frameCount: openGopCounts.count, leadingCounts: openGopCounts)
        model.splitPoints = [8]
        model.currentFrame = 7 // mid-GOP; snaps to 8, where the split already sits

        model.toggleSplit()

        #expect(model.splitPoints.isEmpty)
        #expect(model.currentFrame == 8)
    }

    /// No copy-safe keyframe anywhere → a split has nowhere legal to land: a no-op.
    @Test func toggleSplitIsANoOpWhenNoCopySafeKeyframeExists() {
        let model = makeModel(fieldCoded: true)
        model.primeForTesting(frameCount: 3, leadingCounts: [nil, 2, nil])
        model.currentFrame = 1

        model.toggleSplit()

        #expect(model.splitPoints.isEmpty)
        #expect(model.currentFrame == 1)
    }

    /// A progressive clip splits at the exact raw playhead frame — unchanged from
    /// before #96.
    @Test func progressiveClipSplitsAtTheRawFrameExactly() {
        let model = makeModel(fieldCoded: false)
        model.primeForTesting(frameCount: openGopCounts.count, leadingCounts: openGopCounts)
        model.currentFrame = 6

        model.toggleSplit()

        #expect(model.splitPoints == [6])
        #expect(model.currentFrame == 6)
    }

    // MARK: - Zero behavior change outside field-coded H.264

    /// A progressive clip (even in H.264, and even with a leading-count shape that
    /// would snap elsewhere) marks the exact raw playhead frame — unchanged from
    /// before #96 — including the original conflict rule against the raw value.
    @Test func progressiveClipTakesTheRawFrameExactly() {
        let model = makeModel(fieldCoded: false)
        model.primeForTesting(frameCount: openGopCounts.count, leadingCounts: openGopCounts)
        model.outPoint = 5
        model.currentFrame = 6

        model.setIn()

        #expect(model.inPoint == 6)
        #expect(model.outPoint == nil) // original rule: 5 < 6 clears it
        #expect(model.currentFrame == 6)
    }

    /// A clip whose field-coded probe hasn't resolved yet (`fieldCoded == nil`) must
    /// not snap — only a *confirmed* field-coded source does.
    @Test func fieldCodedNilDoesNotSnap() {
        let model = makeModel(fieldCoded: nil)
        model.primeForTesting(frameCount: openGopCounts.count, leadingCounts: openGopCounts)
        model.currentFrame = 6

        model.setIn()

        #expect(model.inPoint == 6)
        #expect(model.currentFrame == 6)
    }

    /// A field-coded clip whose codec isn't H.264 has no validated copy-cut recipe
    /// (`FieldCodedSupport.canRepairFieldCoded`), so it doesn't snap either.
    @Test func nonH264FieldCodedCodecDoesNotSnap() {
        let model = makeModel(fieldCoded: true, codec: "hevc")
        model.primeForTesting(frameCount: openGopCounts.count, leadingCounts: openGopCounts)
        model.currentFrame = 6

        model.setOut()

        #expect(model.outPoint == 6)
        #expect(model.currentFrame == 6)
    }
}
