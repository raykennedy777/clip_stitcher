import Testing
import Foundation
@testable import ClipStitcher

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
        let chain = PreviewFilter.spatialConformChain(
            source: video(1920, 1080), target: video(704, 528),
            canvasW: 704, canvasH: 528)
        #expect(chain == "scale=704:396,pad=704:528:0:66")
    }

    @Test func narrowerSourcePillarboxesOntoTheCanvas() {
        let chain = PreviewFilter.spatialConformChain(
            source: video(704, 528), target: video(1920, 1080),
            canvasW: 1280, canvasH: 720)
        #expect(chain == "scale=960:720,pad=1280:720:160:0")
    }

    @Test func interlacedSourceDeinterlacesBeforeScaling() {
        let chain = PreviewFilter.spatialConformChain(
            source: video(720, 576, sar: "64:45", field: "tt"), target: video(704, 528),
            canvasW: 704, canvasH: 528)
        #expect(chain == "bwdif=mode=0,scale=704:396,pad=704:528:0:66")
    }

    @Test func matchingDisplayAspectScaleFillsWithNoBars() {
        let chain = PreviewFilter.spatialConformChain(
            source: video(720, 576, sar: "64:45", field: "progressive"), target: video(1920, 1080),
            canvasW: 1280, canvasH: 720)
        #expect(chain == "scale=1280:720")
    }

    @Test func interlacedTargetGetsNoInterlaceFilter() {
        let chain = PreviewFilter.spatialConformChain(
            source: video(1920, 1080), target: video(720, 576, sar: "64:45", field: "tt"),
            canvasW: 1024, canvasH: 576)
        #expect(chain == "scale=1024:576")
    }
}
