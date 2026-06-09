import Foundation

/// Builds the **spatial** part of a conformed clip's filter chain for the preview's
/// decode pipeline (ADR-0012): deinterlace, scale, and letterbox/pillarbox onto the
/// preview canvas. The real conform's temporal and encoder steps (`fps`, `interlace`,
/// `format`, color tags) are deliberately absent — frame rate is handled by the
/// timeline's time mapping, and the preview always renders progressive RGB.
///
/// Unlike `ConformEngine.scaleAndPad` (which works in the target's storage pixels),
/// this computes in the canvas's square-pixel **display** space, because the preview
/// canvas is the target's display size.
enum PreviewFilter {
    /// The `-vf` chain that renders `source` frames onto a `canvasW`×`canvasH` canvas
    /// the way the conformed output will look: scale-fill when the display aspects
    /// match, scale-to-fit + centred black bars when they differ. Deinterlaces first
    /// when the source is interlaced and the target progressive, so scaling works on
    /// whole frames — mirroring `ConformEngine.filterChain`'s spatial decisions.
    static func spatialConformChain(
        source: VideoProperties, target: VideoProperties, canvasW: Int, canvasH: Int
    ) -> String {
        var filters: [String] = []
        if ConformEngine.isInterlaced(source.fieldOrder), !ConformEngine.isInterlaced(target.fieldOrder) {
            filters.append("bwdif=mode=0")
        }
        let srcDAR = ConformEngine.displayAspect(source)
        let canvasDAR = Double(canvasW) / Double(canvasH)
        if abs(srcDAR - canvasDAR) < 0.01 {
            filters.append("scale=\(canvasW):\(canvasH)")
        } else {
            let (cw, ch) = fittedSize(srcDAR: srcDAR, canvasW: canvasW, canvasH: canvasH)
            filters.append("scale=\(cw):\(ch)")
            filters.append("pad=\(canvasW):\(canvasH):\((canvasW - cw) / 2):\((canvasH - ch) / 2)")
        }
        return filters.joined(separator: ",")
    }

    /// Content size (even, never exceeding the canvas) that fits `srcDAR` inside the
    /// canvas: wider sources letterbox (bars top/bottom), narrower ones pillarbox.
    private static func fittedSize(srcDAR: Double, canvasW: Int, canvasH: Int) -> (Int, Int) {
        let canvasDAR = Double(canvasW) / Double(canvasH)
        let w: Double, h: Double
        if srcDAR >= canvasDAR {
            w = Double(canvasW)
            h = w / srcDAR
        } else {
            h = Double(canvasH)
            w = h * srcDAR
        }
        return (min(canvasW, even(w)), min(canvasH, even(h)))
    }

    private static func even(_ value: Double) -> Int {
        let n = Int(value.rounded())
        return n % 2 == 0 ? n : n + 1
    }
}
