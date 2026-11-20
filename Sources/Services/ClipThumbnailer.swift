import Foundation

actor ClipThumbnailer {
    static let shared = ClipThumbnailer()

    private static let maxWidth = 88
    private static let maxHeight = 64

    private var cache: [String: Data] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]

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
            .appendingPathComponent("clipstitcher-thumb-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var args = ["-hide_banner", "-loglevel", "error"]
        if let seek { args += ["-ss", seek] }
        args += [
            "-i", url.path, "-an",
            "-vf", "scale=iw*sar:ih,scale=\(maxWidth):\(maxHeight):force_original_aspect_ratio=decrease",
            "-frames:v", "1", "-y", tmp.path,
        ]
        _ = try? await ProcessRunner.run(ffmpeg, args)
        return try? Data(contentsOf: tmp)
    }
}
