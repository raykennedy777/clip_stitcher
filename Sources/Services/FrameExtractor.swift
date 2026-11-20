import Foundation

enum FrameExtractor {
    private static let previewScale = "scale='min(1280,iw)':-2"

    static func imageData(
        url: URL, index: FrameIndex, frame n: Int,
        width: Int, height: Int, containerStart: Double, filter: String? = nil
    ) async throws -> Data? {
        guard index.count > 0, n >= 0, n < index.count else { return nil }
        let ffmpeg = try FFTools.ffmpegURL()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let anchor = index.keyframeIndex(atOrBefore: n) ?? 0
        let offset = n - anchor
        let anchorPTS = String(format: "%.6f", FrameStreamDecoder.seekSeconds(
            forPts: index.pts[anchor], containerStart: containerStart))

        let scale = filter ?? "scale=\(width):\(height)"

        _ = try? await ProcessRunner.run(ffmpeg, [
            "-hide_banner", "-loglevel", "error",
            "-ss", anchorPTS, "-i", url.path,
            "-an", "-vf", "select=eq(n\\,\(offset)),\(scale)",
            "-frames:v", "1", "-fps_mode", "passthrough",
            "-y", tmp.path,
        ])
        if let data = try? Data(contentsOf: tmp) { return data }

        if n >= index.count - 3 {
            try? FileManager.default.removeItem(at: tmp)
            _ = try? await ProcessRunner.run(ffmpeg, [
                "-hide_banner", "-loglevel", "error",
                "-sseof", "-2", "-i", url.path,
                "-an", "-vf", scale, "-update", "1", "-y", tmp.path,
            ])
            if let data = try? Data(contentsOf: tmp) { return data }
        }

        try? FileManager.default.removeItem(at: tmp)
        let target = index.pts[n]
        let prior = n > 0 ? index.pts[n - 1] : target - 0.04
        let midpoint = String(format: "%.6f", FrameStreamDecoder.seekSeconds(
            forPts: (prior + target) / 2.0, containerStart: containerStart))
        _ = try? await ProcessRunner.run(ffmpeg, [
            "-hide_banner", "-loglevel", "error",
            "-i", url.path, "-ss", midpoint,
            "-an", "-vf", scale, "-frames:v", "1", "-y", tmp.path,
        ])
        return try? Data(contentsOf: tmp)
    }

    static func images(url: URL, index: FrameIndex, from: Int, to: Int,
                       containerStart: Double) async throws -> [Int: Data] {
        guard index.count > 0 else { return [:] }
        let lo = max(0, from)
        let hi = min(index.count - 1, to)
        guard lo <= hi else { return [:] }

        let ffmpeg = try FFTools.ffmpegURL()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-window-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let anchor = index.keyframeIndex(atOrBefore: lo) ?? 0
        let anchorPTS = String(format: "%.6f", FrameStreamDecoder.seekSeconds(
            forPts: index.pts[anchor], containerStart: containerStart))
        let pattern = dir.appendingPathComponent("f_%05d.png").path

        _ = try? await ProcessRunner.run(ffmpeg, [
            "-hide_banner", "-loglevel", "error",
            "-ss", anchorPTS, "-i", url.path, "-an",
            "-vf", "select=between(n\\,\(lo - anchor)\\,\(hi - anchor)),\(previewScale)",
            "-fps_mode", "passthrough",
            "-frames:v", "\(hi - lo + 1)",
            "-y", pattern,
        ])

        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var result: [Int: Data] = [:]
        for (offset, file) in files.enumerated() {
            if let data = try? Data(contentsOf: file) {
                result[lo + offset] = data
            }
        }
        return result
    }
}
