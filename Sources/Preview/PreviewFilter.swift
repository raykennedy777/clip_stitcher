import Foundation

enum PreviewFilter {
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
