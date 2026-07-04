import Foundation

/// Decodes source frames to PNG **data** for the cut-editor preview (ADR-0003).
///
/// Returns compressed bytes rather than decoded images so the cut-editor's cache
/// can hold many frames cheaply (tens of KB each); the model decodes only the one
/// frame it is currently displaying. Frames are downscaled to a preview-friendly
/// width to keep decode/encode fast and memory low.
enum FrameExtractor {
    private static let previewScale = "scale='min(1280,iw)':-2"

    /// A single frame's PNG data, robust across positions.
    ///
    /// Strategy, fastest to most robust:
    ///  1. input-seek to the keyframe at/before the target, select the offset-th frame, stop;
    ///  2. for the final 1-2 frames (a B-frame/EOF-flush quirk), grab via end-relative `-sseof`;
    ///  3. output-seek to a midpoint just before the target — slow but always correct.
    static func imageData(
        url: URL, index: FrameIndex, frame n: Int,
        width: Int, height: Int, containerStart: Double, filter: String? = nil
    ) async throws -> Data? {
        guard index.count > 0, n >= 0, n < index.count else { return nil }
        let ffmpeg = try FFTools.ffmpegURL()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // No keyframe at/before n → anchor on the earliest frame; the input seek still
        // lands on the file's first decodable position and the offset counts forward from it.
        let anchor = index.keyframeIndex(atOrBefore: n) ?? 0
        let offset = n - anchor
        // Both input and output `-ss` are measured from the container's start_time,
        // not absolute pts (issue #36 — verified for the output seek too).
        let anchorPTS = String(format: "%.6f", FrameStreamDecoder.seekSeconds(
            forPts: index.pts[anchor], containerStart: containerStart))

        // Match the persistent decoder: scale to the display dimensions (SAR applied),
        // or the caller's chain (the preview's spatial conform, ADR-0012).
        let scale = filter ?? "scale=\(width):\(height)"

        // 1. Fast path.
        _ = try? await ProcessRunner.run(ffmpeg, [
            "-hide_banner", "-loglevel", "error",
            "-ss", anchorPTS, "-i", url.path,
            "-an", "-vf", "select=eq(n\\,\(offset)),\(scale)",
            "-frames:v", "1", "-fps_mode", "passthrough",
            "-y", tmp.path,
        ])
        if let data = try? Data(contentsOf: tmp) { return data }

        // 2. Tail flush for the last couple of frames.
        if n >= index.count - 3 {
            try? FileManager.default.removeItem(at: tmp)
            _ = try? await ProcessRunner.run(ffmpeg, [
                "-hide_banner", "-loglevel", "error",
                "-sseof", "-2", "-i", url.path,
                "-an", "-vf", scale, "-update", "1", "-y", tmp.path,
            ])
            if let data = try? Data(contentsOf: tmp) { return data }
        }

        // 3. Output-seek fallback.
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

    /// Decodes a contiguous range `[from, to]` (presentation order) in one ffmpeg
    /// pass, returning PNG data keyed by frame number. ~15× cheaper per frame than
    /// one process per frame — this is what makes cached stepping instant. The
    /// final 1-2 frames may be absent (EOF-flush quirk); backfill with `imageData`.
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

        // No keyframe at/before the range start → anchor on the earliest frame (see `imageData`).
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
