import Foundation

enum SceneScan {
    static let threshold = 0.3
    static let windowSeconds = 5.0
    static let guardSeconds = 2.0

    static func arguments(inputPath: String, seekStart: Double, duration: Double, deinterlace: Bool) -> [String] {
        let filter = (deinterlace ? "yadif=0," : "")
            + "select='gt(scene,\(threshold))',metadata=print:file=-"
        return [
            "-v", "error", "-nostdin",
            "-hwaccel", "videotoolbox",
            "-copyts",
            "-ss", String(format: "%.6f", seekStart),
            "-t", String(format: "%.6f", duration),
            "-i", inputPath,
            "-an", "-sn",
            "-vf", filter,
            "-f", "null", "-",
        ]
    }

    static func parsePTSTimes(_ output: String) -> [Double] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let range = line.range(of: "pts_time:") else { return nil }
            return Double(line[range.upperBound...].prefix(while: { !$0.isWhitespace && $0 != "," }))
        }
    }

    static func nearestFrame(toPTS t: Double, in pts: [Double]) -> Int {
        guard !pts.isEmpty else { return 0 }
        var lo = 0
        var hi = pts.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if pts[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, t - pts[lo - 1] < pts[lo] - t { return lo - 1 }
        return lo
    }

    static func forwardLanding(sceneFrames: [Int], current: Int, cap: Int) -> Int {
        sceneFrames.filter { $0 > current && $0 <= cap }.min() ?? cap
    }

    static func backwardLanding(sceneFrames: [Int], current: Int, floor: Int) -> Int {
        sceneFrames.filter { $0 < current && $0 >= floor }.max() ?? floor
    }

    static func sceneFrames(
        url: URL, seekStart: Double, duration: Double, deinterlace: Bool, pts: [Double]
    ) async -> [Int] {
        guard let ffmpeg = try? FFTools.ffmpegURL() else { return [] }
        let args = arguments(
            inputPath: url.path, seekStart: seekStart, duration: duration, deinterlace: deinterlace)
        guard let result = try? await ProcessRunner.run(ffmpeg, args), result.status == 0 else {
            return []
        }
        let output = String(decoding: result.stdout, as: UTF8.self)
        return parsePTSTimes(output).map { nearestFrame(toPTS: $0, in: pts) }
    }
}
