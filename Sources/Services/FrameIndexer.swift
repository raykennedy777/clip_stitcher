import Foundation

/// Establishes a clip's exact frame count by counting video packets (see ADR-0006).
///
/// Slice 1 produces the accurate total frame count, which is what the Source view
/// needs. The deeper per-frame index (frame → PTS + keyframe map) used by the
/// cut-editor and the keyframe-aligned export is built in a later slice, where it
/// is first needed.
enum FrameIndexer {
    static func frameCount(url: URL) async throws -> Int {
        let ffprobe = try FFTools.ffprobeURL()
        let output = try await ProcessRunner.run(ffprobe, [
            "-v", "error",
            "-select_streams", "v:0",
            "-count_packets",
            "-show_entries", "stream=nb_read_packets",
            "-of", "default=nokey=1:noprint_wrappers=1",
            url.path,
        ])
        guard output.status == 0 else {
            throw FFError.indexFailed(String(data: output.stderr, encoding: .utf8) ?? "exit \(output.status)")
        }
        // TS files report the video stream twice (once nested under its program,
        // once in the flat stream list), so ffprobe can print the count on more
        // than one line. Take the first integer-parseable line.
        let text = String(data: output.stdout, encoding: .utf8) ?? ""
        for line in text.split(whereSeparator: \.isNewline) {
            if let count = Int(line.trimmingCharacters(in: .whitespaces)) {
                return count
            }
        }
        return 0
    }
}
