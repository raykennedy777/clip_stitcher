import Testing
import Foundation
@testable import VidConform

/// Pins the preview's spatial conform chain (ADR-0012): the deinterlace/scale/pad
/// decisions mirror ConformEngine's, computed in the canvas's square-pixel display
/// space. The recipes were validated 1-frame-in-1-frame-out against the real
/// H.264/MPEG-2/HEVC footage in the shell.
struct PreviewFilterTests {
    private func video(
        _ width: Int, _ height: Int, sar: String = "1:1", field: String = "progressive"
    ) -> VideoProperties {
        VideoProperties(
            codec: "h264", profile: nil, level: nil,
            width: width, height: height, frameRate: "25/1",
            pixelFormat: "yuv420p", fieldOrder: field, sampleAspectRatio: sar,
            colorPrimaries: nil, colorTransfer: nil, colorRange: nil
        )
    }

    @Test func widerSourceLetterboxesOntoTheCanvas() {
        // The HD 16:9 conform source into the 4:3 target's 704×528 canvas.
        let chain = PreviewFilter.spatialConformChain(
            source: video(1920, 1080), target: video(704, 528),
            canvasW: 704, canvasH: 528)
        #expect(chain == "scale=704:396,pad=704:528:0:66")
    }

    @Test func narrowerSourcePillarboxesOntoTheCanvas() {
        // A 4:3 clip into a 16:9 HD target's 1280×720 canvas.
        let chain = PreviewFilter.spatialConformChain(
            source: video(704, 528), target: video(1920, 1080),
            canvasW: 1280, canvasH: 720)
        #expect(chain == "scale=960:720,pad=1280:720:160:0")
    }

    @Test func interlacedSourceDeinterlacesBeforeScaling() {
        // The PAL 16:9 interlaced MPEG-2 (720×576 SAR 64:45, tt) into a progressive
        // 4:3 target: bwdif first, then letterbox.
        let chain = PreviewFilter.spatialConformChain(
            source: video(720, 576, sar: "64:45", field: "tt"), target: video(704, 528),
            canvasW: 704, canvasH: 528)
        #expect(chain == "bwdif=mode=0,scale=704:396,pad=704:528:0:66")
    }

    @Test func matchingDisplayAspectScaleFillsWithNoBars() {
        // The same PAL 16:9 anamorphic source into a 16:9 HD canvas: aspects match in
        // display space, so plain scale — no pad.
        let chain = PreviewFilter.spatialConformChain(
            source: video(720, 576, sar: "64:45", field: "progressive"), target: video(1920, 1080),
            canvasW: 1280, canvasH: 720)
        #expect(chain == "scale=1280:720")
    }

    @Test func interlacedTargetGetsNoInterlaceFilter() {
        // Conforming *to* an interlaced target interlaces the output, but the preview
        // always renders progressive frames (ADR-0012) — no scan filter either way.
        let chain = PreviewFilter.spatialConformChain(
            source: video(1920, 1080), target: video(720, 576, sar: "64:45", field: "tt"),
            canvasW: 1024, canvasH: 576)
        #expect(chain == "scale=1024:576")
    }
}
