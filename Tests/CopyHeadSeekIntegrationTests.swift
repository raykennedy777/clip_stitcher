import Testing
import Foundation
@testable import ClipStitcher

/// End-to-end net for the copy head seek (issue #108): a copy segment must skip the source
/// *before* its in-cut instead of writing it out as a discarded segment, and the piece it
/// produces must be **packet-identical** to the read-from-zero recipe it replaces.
///
/// The unit suites pin the pure decisions — where the anchor keyframe sits, how the segment
/// times rebase onto the measured landing, that `-copyts` stays off the real run. Only a real
/// ffmpeg run can show that the composed recipe still lands the split on the same keyframe,
/// which is the thing that fails silently: an origin off by one GOP yields a piece with the
/// *right frame count* and the wrong frames, so no count-based gate catches it. The de-risk
/// that motivated this measured exactly that failure before the landing was probed.
///
/// **Owns no copyrighted bytes (ADR-0023).** The sources are synthesised from `testsrc2`
/// (a few seconds each) into a fully-gitignored folder and cached there, so this suite runs
/// on a fresh clone with nothing supplied. It is long-GOP by construction — a keyframe a
/// second — and the in-cut sits ~5/6 of the way in, which is the shape that made the head
/// dominate a render: on the real 4h36 capture one 54 s copy 150 min in discarded 8.6 GB.
///
/// It runs in the everyday suite — ~11 s, and a couple of seconds more the first time, when it
/// synthesises its sources. Isolate it with
/// `-only-testing:ClipStitcherTests/CopyHeadSeekIntegrationTests`.
@Suite("Copy head seek (integration)", .serialized)
struct CopyHeadSeekIntegrationTests {

    /// One synthesised long-GOP source. All three codecs, because a copy recipe that works on
    /// one routinely breaks on another: MPEG-2 brings a non-zero container start (the `.mpg`
    /// muxer starts at 0.54 s) and the Matroska missing-PTS refill (issue #2), and open-GOP
    /// HEVC brings the landing that undershoots the keyframe it was asked for.
    struct Source {
        var name: String
        var codec: String
        var encoder: [String]
        var rate: Int
        var gop: Int
    }

    static let sources = [
        Source(name: "h264", codec: "h264",
               encoder: ["-c:v", "libx264", "-preset", "ultrafast", "-crf", "30",
                         "-g", "50", "-keyint_min", "50", "-bf", "3"],
               rate: 50, gop: 50),
        Source(name: "hevc", codec: "hevc",
               encoder: ["-c:v", "libx265", "-preset", "ultrafast", "-crf", "32",
                         "-x265-params", "open-gop=1:keyint=50:min-keyint=50:bframes=4"],
               rate: 50, gop: 50),
        Source(name: "mpeg2", codec: "mpeg2video",
               encoder: ["-c:v", "mpeg2video", "-q:v", "6", "-g", "25", "-bf", "2"],
               rate: 25, gop: 25),
    ]

    /// 180 s at a keyframe a second: long enough that the pre-in-cut head is most of the file,
    /// short enough to synthesise in a second or two and cache in a few tens of MB.
    static let seconds = 180

    static var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/head-seek")
    }

    /// The cached source for one codec, synthesised on first use. `.mpg` for MPEG-2 so the
    /// container contributes its own non-zero start time.
    static func source(_ spec: Source) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        let url = fixtureDirectory
            .appendingPathComponent("src_\(spec.name).\(spec.codec == "mpeg2video" ? "mpg" : "mkv")")
        if fm.fileExists(atPath: url.path) { return url }
        let ffmpeg = try FFTools.ffmpegURL()
        let args = ["-v", "error", "-y", "-f", "lavfi",
                    "-i", "testsrc2=size=640x360:rate=\(spec.rate):duration=\(seconds)"]
            + spec.encoder + ["-pix_fmt", "yuv420p", url.path]
        let result = try await ProcessRunner.run(ffmpeg, args)
        guard result.status == 0, fm.fileExists(atPath: url.path) else {
            throw ExportError.cutFailed(String(data: result.stderr, encoding: .utf8) ?? "synthesis failed")
        }
        return url
    }

    /// A piece's packets as the de-risk compared them: timestamps, sizes and flags. Byte
    /// comparison is useless here — two identical Matroska muxes differ in the segment UID
    /// and the muxing date — and packet *count* alone is what an off-by-one-GOP split passes.
    static func fingerprint(_ url: URL) async throws -> [String] {
        let ffprobe = try FFTools.ffprobeURL()
        let result = try await ProcessRunner.run(ffprobe, [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "packet=pts_time,dts_time,size,flags", "-of", "csv=p=0", url.path,
        ])
        let text = String(data: result.stdout, encoding: .utf8) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    static func totalBytes(in directory: URL) -> Int {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.reduce(0) { sum, name in
            let attrs = try? fm.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            return sum + ((attrs?[.size] as? Int) ?? 0)
        }
    }

    static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-headseek-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The whole claim in one run, per codec and per output container.
    ///
    /// 1. the piece `produceVideoPiece` ships is packet-for-packet what the unseeked segment
    ///    muxer shipped — same split, same frames, same timestamps;
    /// 2. the run no longer reads the source before the clip, so its temp footprint collapses
    ///    from most-of-the-file to a couple of GOPs;
    /// 3. nothing dead is left behind afterwards.
    @Test(arguments: [("h264", "mkv"), ("h264", "mp4"), ("h264", "ts"),
                      ("hevc", "mkv"), ("hevc", "mp4"), ("hevc", "ts"),
                      ("mpeg2", "mkv"), ("mpeg2", "mp4"), ("mpeg2", "ts")])
    func aSeekedCopyShipsTheSamePieceForAFractionOfTheTemp(codec: String, ext: String) async throws {
        let spec = Self.sources.first { $0.name == codec }!
        let src = try await Self.source(spec)
        let ffmpeg = try FFTools.ffmpegURL()
        let index = try await FrameIndexer.buildIndex(url: src)
        let containerStart = await MediaProbe.containerStartTime(url: src)
        let start = try #require(index.pts.first)

        // A copy span 5/6 of the way in — the in-point regime where the head dominated.
        let keyframes = (0..<index.count).filter { index.keyframeFlags[$0] }
        let lo = try #require(keyframes.last { index.pts[$0] - start <= 150 })
        let outCut = try #require(keyframes.first { index.pts[$0] - start >= 155 })
        let copyPlan = BoundaryReencodeEngine.copySegmentPlan(
            copyRange: lo..<outCut, outCutKeyframe: outCut, index: index)
        #expect(copyPlan.inSegmentTime != nil, "the span must have a head to skip")
        let bsf = ExportEngine.copyPieceBitstreamFilter(codec: spec.codec, ext: ext)

        // The reference: today's read-from-zero recipe, run exactly as `cutArguments` builds it.
        let refDir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: refDir) }
        let refRun = try await ProcessRunner.run(ffmpeg, ExportEngine.cutArguments(
            source: src, plan: copyPlan,
            segmentPattern: refDir.appendingPathComponent("ref_%03d.\(ext)").path,
            bitstreamFilter: bsf))
        #expect(refRun.status == 0,
                "reference cut: \(String(data: refRun.stderr, encoding: .utf8) ?? "")")
        let reference = refDir.appendingPathComponent(
            String(format: "ref_%03d.\(ext)", ExportEngine.wantedSegmentIndex(plan: copyPlan)))
        let referencePackets = try await Self.fingerprint(reference)
        let referenceBytes = Self.totalBytes(in: refDir)

        // The plan the executor gets is sized to what the cut actually keeps: on an open-GOP
        // end the copy range stops short of the out-cut keyframe by its leading pictures
        // (#16), and the reference run is the honest measure of that.
        let plan = [PlannedSegment(kind: .copy, range: lo..<(lo + referencePackets.count),
                                   outCutKeyframe: outCut)]

        let work = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: work) }
        let piece = try await BoundaryReencodeEngine.produceVideoPiece(
            ffmpeg, source: src, plan: plan, index: index,
            encoder: ["-c:v", "libx264", "-pix_fmt", "yuv420p"], work: work, ext: ext,
            clipIndex: 0, codec: spec.codec, containerStart: containerStart)

        // 1. same piece, packet for packet — the split landed on the same keyframe.
        let producedPackets = try await Self.fingerprint(piece)
        #expect(producedPackets == referencePackets)

        // 2. the head is gone. The reference wrote the whole source up to the out-cut; the
        //    seeked run writes the wanted piece plus a couple of GOPs of pre-roll.
        let seekedBytes = Self.totalBytes(in: work)
        let pieceBytes = (try? FileManager.default
            .attributesOfItem(atPath: piece.path)[.size] as? Int) ?? 0
        #expect(seekedBytes < referenceBytes / 4,
                "temp \(seekedBytes) vs unseeked \(referenceBytes)")
        #expect(seekedBytes < pieceBytes * 3,
                "the read should be the span plus pre-roll, not the file before it")

        // 3. and the run's dead segments went with it.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
        #expect(leftovers == [piece.lastPathComponent],
                "left behind: \(leftovers.sorted())")
    }

    /// The guard that keeps a bad seek from ever reaching the muxer: the landing has to be
    /// strictly before the in-cut, or segment `000` gets no packets, ffmpeg never writes it,
    /// and `wantedSegmentIndex`'s `001` names a file that doesn't exist. A copy starting at
    /// the file's own first keyframe has no earlier keyframe to anchor on, so it takes no
    /// seek at all — and still produces its piece.
    @Test func aCopyWithNoRoomToSeekFallsBackToTheUnseekedRead() async throws {
        let src = try await Self.source(Self.sources[0])
        let ffmpeg = try FFTools.ffmpegURL()
        let index = try await FrameIndexer.buildIndex(url: src)
        let containerStart = await MediaProbe.containerStartTime(url: src)

        // in-cut at the very first frame: no keyframe before it
        let atStart = SegmentPlan(inFrame: 0, outFrame: 100, inSegmentTime: 0.0, outSegmentTime: 2.0)
        #expect(ExportEngine.copyHeadSeekTarget(
            plan: atStart, index: index, containerStart: containerStart) == nil)
        let probeDir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: probeDir) }
        #expect(await BoundaryReencodeEngine.copyHeadSeek(
            ffmpeg, source: src, plan: atStart, index: index, containerStart: containerStart,
            probeOutput: probeDir.appendingPathComponent("probe.nut")) == nil)

        // the second keyframe: one earlier keyframe only, which is still enough
        let keyframes = (0..<index.count).filter { index.keyframeFlags[$0] }
        let second = keyframes[1]
        let plan = BoundaryReencodeEngine.copySegmentPlan(
            copyRange: second..<keyframes[3], outCutKeyframe: keyframes[3], index: index)
        let seek = await BoundaryReencodeEngine.copyHeadSeek(
            ffmpeg, source: src, plan: plan, index: index, containerStart: containerStart,
            probeOutput: probeDir.appendingPathComponent("probe2.nut"))
        let measured = try #require(seek)
        #expect(measured.origin < plan.inSegmentTime!)
        // the probe left nothing behind
        #expect((try? FileManager.default.contentsOfDirectory(atPath: probeDir.path)) == [])
    }
}
