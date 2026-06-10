import Foundation

/// Extracts and caches the tiny thumbnail shown beside each clip in the source
/// list (issue #23) — taken at the start of the clip's selection, or near the
/// file's start when nothing is selected.
///
/// One cheap ffmpeg call per source file, deliberately independent of the clip's
/// `FrameIndex` (which is built lazily and is far too heavy a dependency for a
/// list decoration) — so the thumbnail can appear while the clip is still
/// probing or indexing. De-risked in the shell on all three target formats:
/// ~30 ms on MPEG-2/H.264, ~230 ms on open-GOP 1080p HEVC.
actor ClipThumbnailer {
    static let shared = ClipThumbnailer()

    /// 2× the row's 44×32 display box, for Retina.
    private static let maxWidth = 88
    private static let maxHeight = 64

    private var cache: [String: Data] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]

    /// PNG data for the thumbnail at roughly `seconds` into the source (nil for
    /// the near-start default), cached per (file path, time) so duplicated clips
    /// with the same selection share a single extraction. Returns nil when no
    /// frame could be decoded (and doesn't cache the failure, so a relinked or
    /// repaired source gets retried).
    func pngData(for url: URL, atSeconds seconds: Double?) async -> Data? {
        let key = "\(url.path)@\(seconds.map { String(format: "%.3f", $0) } ?? "start")"
        if let hit = cache[key] { return hit }
        if let pending = inFlight[key] { return await pending.value }
        let task = Task { await Self.extract(url: url, seconds: seconds) }
        inFlight[key] = task
        let data = await task.value
        inFlight[key] = nil
        if let data { cache[key] = data }
        return data
    }

    /// The first frame at/after the requested time — an input seek lands on the
    /// keyframe just before it, so this stays cheap anywhere in the file. With
    /// no time (or one ffmpeg can't satisfy, e.g. past EOF) it falls back to
    /// ~1 s — skipping a black opening frame — and finally to the very first
    /// frame for sub-second files.
    private static func extract(url: URL, seconds: Double?) async -> Data? {
        if let seconds, seconds > 1,
           let data = await run(url: url, seek: String(format: "%.3f", seconds)) {
            return data
        }
        if let data = await run(url: url, seek: "1") { return data }
        return await run(url: url, seek: nil)
    }

    private static func run(url: URL, seek: String?) async -> Data? {
        guard let ffmpeg = try? FFTools.ffmpegURL() else { return nil }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vidconform-thumb-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var args = ["-hide_banner", "-loglevel", "error"]
        if let seek { args += ["-ss", seek] }
        // `scale=iw*sar:ih` squares anamorphic pixels first so DVD-shaped
        // sources aren't squashed (the ADR-0012 gotcha), then fit the box.
        args += [
            "-i", url.path, "-an",
            "-vf", "scale=iw*sar:ih,scale=\(maxWidth):\(maxHeight):force_original_aspect_ratio=decrease",
            "-frames:v", "1", "-y", tmp.path,
        ]
        _ = try? await ProcessRunner.run(ffmpeg, args)
        return try? Data(contentsOf: tmp)
    }
}
