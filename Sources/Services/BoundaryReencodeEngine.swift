import Foundation

/// Milestone 2 export executor (ADR-0009): produces a frame-exact between-keyframes cut
/// by re-encoding the partial head/tail GOPs and stream-copying the keyframe-bounded
/// middle, then concatenating — the recipe validated frame-exact against real
/// H.264/HEVC/MPEG-2 footage in the shell. It executes a `BoundaryReencodePlanner` plan
/// with the bundled ffmpeg CLI only; no in-process libav (ADR-0002).
///
/// The argument builders are pure so the exact command shape can be unit-tested.
enum BoundaryReencodeEngine {
    /// ffmpeg video-encode args matched to the source so the re-encoded GOPs concat
    /// cleanly with the copied middle (ADR-0009): same codec family, pixel format, and
    /// — when it maps to a known encoder profile — the source's profile; plus, for
    /// interlaced MPEG-2, the field flags that preserve `field_order`. SAR is carried
    /// through by ffmpeg automatically, so no `-aspect` is needed (verified).
    ///
    /// In practice the pixel format already pins the profile for the common cases
    /// (yuv420p10le ⇒ libx265 main10, yuv420p ⇒ libx264 high / mpeg2 main — all verified
    /// against the real footage). `-profile:v` is added for robustness so an *unusual*
    /// source (e.g. a Baseline H.264 clip that would otherwise re-encode to High) still
    /// matches; an unrecognised profile string is omitted rather than guessed, leaving the
    /// encoder's working inference in place.
    static func reencodeVideoArgs(
        codec: String?, profile: String? = nil, pixelFormat: String?, fieldOrder: String?,
        bitrate: Int? = nil
    ) -> [String] {
        let pixFmt = pixelFormat ?? "yuv420p"
        var args = ["-c:v", EncoderSelection.encoder(for: codec), "-pix_fmt", pixFmt]
        if let p = EncoderSelection.encoderProfile(profile, codec: EncoderSelection.profileCodec(for: codec)) {
            args += ["-profile:v", p]
        }
        if codec == "mpeg2video" {
            switch fieldOrder {
            case "tt", "tb": args += ["-flags", "+ildct+ilme", "-top", "1"]
            case "bb", "bt": args += ["-flags", "+ildct+ilme", "-top", "0"]
            default: break   // progressive / unknown — no interlace flags
            }
        }
        return args + rateControlArgs(codec: codec, bitrate: bitrate)
    }

    /// The **near-lossless CRF every re-encoded piece is held to** (issue #110) — the same
    /// fixed engine constant `mbaffRepairVideoArgs` already pins for the same reason
    /// (issue #54), not a user control: a boundary piece is seconds-to-minutes inside an
    /// otherwise stream-copied file and has no target spec of its own to express
    /// (`OutputSettings.conformCrf` stays conform-only).
    static let reencodeCrf = 18

    /// The fixed quantiser an MPEG-2 re-encode falls back to when the source's bitrate
    /// couldn't be measured at all. Near the top of mpeg2video's 1–31 scale, so the piece is
    /// bigger than the source (measured 6.6 vs 2.5 Mbps, PSNR-Y 48.2 dB) but never a quality
    /// regression — the export still completes, just less efficiently.
    static let reencodeMpeg2Quantiser = 2

    /// How far above the source's measured average an MPEG-2 re-encode aims. Deliberate
    /// headroom: re-encoding already-decoded frames is less efficient than the original
    /// encode, so matching the average exactly reads as slightly softer than the copied
    /// content either side. ~25 % more bytes across those seconds is the right trade for a
    /// seam nobody can see.
    static let reencodeBitrateHeadroom = 1.25

    /// Rate control for a re-encoded piece, per codec family (issue #110). Without this every
    /// piece encoded at its encoder's own default — CRF 28 on libx265, 23 on libx264, and on
    /// mpeg2video ffmpeg's 200 kbps with the quantiser pinned at its 31 ceiling — so a
    /// boundary re-encode landed at *half* the bitrate of the copied content beside it
    /// (measured 2292 vs 5476 kbps on a real master, over ~2 minutes of content where the
    /// source had no keyframe near the in-point).
    ///
    /// libx264/libx265 take the fixed `reencodeCrf`. **mpeg2video has no CRF mode**, so it
    /// targets a bitrate derived from the source instead — the re-encoded span should just
    /// look like part of the source — with `-maxrate`/`-bufsize` bounding the peaks at 1.5×
    /// and 2× the target. De-risked in the shell on the real interlaced MPEG-PS fixture, in
    /// the real output containers: the piece comes out at 3.37 Mbps against the source's
    /// 2.53 (PSNR-Y 43.9 dB, against 34.0 dB for the old default), keeps `field_order`, SAR
    /// and profile, and still concats cleanly with a copy piece into .mpg/.ts/.mkv with the
    /// frame count and decode identical to before.
    static func rateControlArgs(codec: String?, bitrate: Int?) -> [String] {
        guard codec == "mpeg2video" else { return ["-crf", String(reencodeCrf)] }
        guard let bitrate, bitrate > 0 else { return ["-q:v", String(reencodeMpeg2Quantiser)] }
        let target = Int((Double(bitrate) * reencodeBitrateHeadroom).rounded())
        return ["-b:v", String(target),
                "-maxrate", String(target * 3 / 2),
                "-bufsize", String(target * 2)]
    }

    /// libx264 encode args for the **field-coded (PAFF) damage-to-EOF repair** (issue #54,
    /// ADR-0022). A no-IDR PAFF source cannot be smart-render spliced — the MBAFF→PAFF
    /// resume seam is a hard container-layer wall, and this ffmpeg build has no PAFF-capable
    /// H.264 encoder — so Clip Doctor copies the clean head byte-for-byte and re-encodes
    /// everything from the first damage to EOF as **MBAFF** H.264 (one continuous segment).
    /// This is the encoder for that single tail re-encode; the copy head carries the
    /// source's own field pictures untouched.
    ///
    /// The recipe was de-risked end-to-end on a real PAFF slice (decodes `-xerror` to EOF
    /// clean, seam clean, `field_order` preserved, strict-DTS clean once muxed):
    ///   - `+ildct+ilme` + `-top` (from `field_order`: `tt`/`tb` ⇒ top-field-first ⇒ 1,
    ///     `bb`/`bt` ⇒ 0) keep the output interlaced TFF/BFF matching the source scan;
    ///   - **`-crf 18` is a fixed engine constant**, not a user control — visually lossless
    ///     (VMAF ≈ 99, ~1.33× source bitrate), well above the app's crf-23 default, the
    ///     quality a repair-only export owes a broadcast capture;
    ///   - `-forced-idr 1` + `open_gop=0` make the tail's first frame a clean IDR so the
    ///     single copy→MBAFF *entry* seam re-initialises the decoder;
    ///   - `ref=5:level=4.0` matches the source's out-of-spec 5-ref-at-L4.0 cadence,
    ///     `b-pyramid=0` avoids the MKV/TS duplicate-PTS collapse (issue #2), `keyint=25`
    ///     keeps seekable GOPs, `scenecut=0` keeps them regular.
    ///
    /// The `dump_extra` this recipe used to append itself — repeating SPS/PPS into the stream
    /// so the entry seam re-inits cleanly — now comes from the segment argument builders, which
    /// apply it to **every** re-encoded piece for the same reason (issue #113,
    /// `ExportEngine.parameterSetRepeatFilter`). Keeping it here too would emit a second
    /// `-bsf:v` that silently replaced the first rather than adding to it.
    static func mbaffRepairVideoArgs(fieldOrder: String?) -> [String] {
        let top = (fieldOrder == "bb" || fieldOrder == "bt") ? "0" : "1"
        return [
            "-c:v", "libx264", "-flags", "+ildct+ilme", "-top", top,
            "-preset", "medium", "-crf", "18", "-forced-idr", "1",
            "-x264-params", "ref=5:keyint=25:scenecut=0:open_gop=0:b-pyramid=0:level=4.0",
        ]
    }

    /// ffmpeg args to re-encode the partial-GOP presentation range `[range.lowerBound,
    /// range.upperBound)` into `output`. To avoid decoding the whole file, it input-seeks
    /// to the keyframe at/before the range start (which the decoder emits as `n = 0`),
    /// then selects frames RELATIVE to that keyframe. The seek is start_time-relative
    /// (ffmpeg subtracts the stream start_time from `-ss`), so the first presentation PTS
    /// is removed. Audio is dropped here; the rebuilt track is muxed in later.
    ///
    /// `-frames:v <range.count>` ends the run at the last kept frame: `select` only
    /// *drops* frames, so without a frame budget ffmpeg keeps decoding from the range's
    /// end to the file's end emitting nothing — on a 72-minute HEVC source that pinned
    /// the CPU for many extra minutes after a 28 s cut, with the encoder's lookahead
    /// not even flushing until that pointless decode hit EOF (test_sprint diagnosis).
    /// De-risked on all three formats: identical frames, the run just stops on time.
    ///
    /// An MP4 piece also pins `-video_track_timescale` to the source's (issue #18): the
    /// concat demuxer reads every listed file in one timebase, and the encoder-default
    /// 1/12800 track otherwise lands mis-scaled next to the source-inherited copy piece,
    /// collapsing the re-encode's frames when the mp4 muxer "repairs" the resulting
    /// non-monotonic DTS. MKV/TS impose a fixed per-container timebase, so the flag is
    /// only emitted for an mp4 output; an unknown timescale omits it rather than guessing.
    static func reencodeSegmentArguments(
        source: URL, range: Range<Int>, index: FrameIndex, encoder: [String], output: URL,
        trackTimescale: Int? = nil
    ) -> [String] {
        // No keyframe at/before the segment start → decode from the earliest frame; the
        // input seek lands on the file's first decodable position and the relative-frame
        // select counts forward from it either way.
        let anchor = index.keyframeIndex(atOrBefore: range.lowerBound) ?? 0
        let startOffset = index.pts.first ?? 0
        let seek = index.pts[anchor] - startOffset
        let relStart = range.lowerBound - anchor
        let relEnd = range.upperBound - 1 - anchor
        var args = ["-v", "error", "-ss", ExportEngine.timeString(seek), "-i", source.path]
        args += ["-vf", "select='between(n\\,\(relStart)\\,\(relEnd))',setpts=PTS-STARTPTS"]
        args += encoder
        args += ["-bsf:v", ExportEngine.parameterSetRepeatFilter]
        if let trackTimescale, output.pathExtension.lowercased() == "mp4" {
            args += ["-video_track_timescale", String(trackTimescale)]
        }
        args += ["-frames:v", String(range.count), "-an", output.path]
        return args
    }

    // MARK: - Repaired segments (#47)

    /// ffmpeg args to re-encode a **repaired** segment — a span the planner forced
    /// around damage zones (issue #47), validated in the shell on all three formats ×
    /// three containers (#43 + #47 de-risk). It differs from `reencodeSegmentArguments`
    /// exactly where damage breaks that recipe:
    ///
    /// - **Selects by time, not frame number**: at every truncated no-timestamp packet
    ///   the index numbering and the decoder's emitted-frame numbering drift apart by
    ///   one, so `between(n,…)` desyncs precisely where it matters. `t` after an input
    ///   seek is `abs_pts − start_time − ss_requested` (the *requested* seek, even when
    ///   the landing differs).
    /// - **Anchors one keyframe early** (two on MPEG-PS, whose byte-estimated time-seek
    ///   lands late — badly so near damage): a truncated final GOP decodes nothing when
    ///   entered directly, and the span bound in the select discards the lead-in anyway.
    /// - **Drops each zone's window and fills with `fps`** at the source rate: the
    ///   dropped span is repaid by repeating the last good frame, so the source
    ///   timeline length is preserved exactly. Each window is widened a quarter frame
    ///   against float jitter, and clamped so the span's first frame always survives —
    ///   `fps` needs a frame to hold, and a glitched held frame beats a shifted
    ///   timeline when damage touches the span head.
    /// - **`-frames:v` is the span's slot budget**: `fps` pads its end-of-stream flush
    ///   to the last *decoded* frame (dropped or kept), so the budget is what truncates
    ///   the fill exactly at the span end. A **truncated ending** (a video zone reaching
    ///   the file end) caps the budget at the frames *before* it, so the output ends on
    ///   the last complete frame instead of `fps` refilling the dropped final slot — the
    ///   sole trim exception to repair's length preservation (CONTEXT.md "Repair").
    static func repairedSegmentArguments(
        source: URL, range: Range<Int>, index: FrameIndex, zones: [DamageZone],
        containerStart: Double, frameRate: String, encoder: [String], output: URL,
        trackTimescale: Int? = nil
    ) -> [String] {
        let fps = ConformEngine.frameRateValue(frameRate) ?? 25
        let interval = 1 / fps
        let quarter = interval / 4
        let anchor = repairAnchor(source: source, range: range, index: index)
        let seek = max(0, index.pts[anchor] - containerStart)
        let spanStart = index.pts[range.lowerBound] - containerStart
        let spanEnd = segmentEndTime(range: range, index: index, frameDuration: interval)
            - containerStart

        var select = "between(t\\,\(ExportEngine.timeString(spanStart - seek - quarter))"
            + "\\,\(ExportEngine.timeString(spanEnd - interval - seek + quarter)))"
        for zone in zones {
            let windowStart = max(zone.start - quarter, spanStart + interval - quarter)
            select += "*not(between(t\\,\(ExportEngine.timeString(windowStart - seek))"
                + "\\,\(ExportEngine.timeString(zone.end - seek + quarter))))"
        }

        var args = ["-v", "error", "-ss", ExportEngine.timeString(seek)]
        args += ["-t", ExportEngine.timeString(spanEnd - (index.pts[anchor] - containerStart) + 1.0)]
        args += ["-i", source.path]
        args += ["-vf", "select='\(select)',setpts=PTS-STARTPTS,fps=\(ConformEngine.fpsToken(frameRate, double: false))"]
        args += encoder
        args += ["-bsf:v", ExportEngine.parameterSetRepeatFilter]
        if let trackTimescale, output.pathExtension.lowercased() == "mp4" {
            args += ["-video_track_timescale", String(trackTimescale)]
        }
        args += ["-frames:v", String(trimmedSlotBudget(range: range, index: index, zones: zones,
                                                        fps: fps, containerStart: containerStart)),
                 "-an", output.path]
        return args
    }

    /// The output slot count for a repaired segment: normally the full `slotBudget` (interior
    /// zones drop + `fps`-fill, source length preserved), but a **truncated ending** trims.
    /// A video zone reaching the file end has nothing after it to keep in sync, so the output
    /// ends on the last complete frame (up to one frame shorter than the source) rather than
    /// `fps` refilling the dropped final slot — repair's sole length-preservation exception
    /// (CONTEXT.md "Repair"/"Truncated ending"). The cap is the frames from the span start up
    /// to the trailing zone's start; interior zones before it are untouched (they still fill).
    static func trimmedSlotBudget(range: Range<Int>, index: FrameIndex, zones: [DamageZone],
                                  fps: Double, containerStart: Double) -> Int {
        let full = slotBudget(range: range, index: index, fps: fps)
        guard range.upperBound == index.count else { return full }   // interior span: no EOF to trim
        let interval = 1 / fps
        let spanStart = index.pts[range.lowerBound] - containerStart
        let spanEnd = segmentEndTime(range: range, index: index, frameDuration: interval) - containerStart
        // A zone is a truncated ending when it runs through the span's final slot.
        guard let cut = zones
            .filter({ $0.affectsVideo && $0.start < spanEnd && $0.end >= spanEnd - interval })
            .map(\.start).min() else { return full }
        return max(1, min(full, Int(((cut - spanStart) * fps).rounded())))
    }

    /// The frame count a repaired piece must come out at: the (possibly trimmed) slot budget,
    /// plus how far short it may legitimately fall. Interior spans fill exactly to
    /// `duration × fps` (holes filled, corrupt frames dropped and held over) — their right
    /// boundary is a clean keyframe that decodes, and the fill pads to it. A **truncated
    /// ending** (a zone through the file end) trims instead of filling (`trimmedSlotBudget`),
    /// so the budget already ends on the last complete frame; the residual shortfall allowance
    /// covers the one uncertainty left — whether that last frame itself decoded (the truncated
    /// packet sits in the index but may not), so the piece may end a frame or two short.
    static func repairedSegmentExpectation(
        range: Range<Int>, index: FrameIndex, zones: [DamageZone],
        containerStart: Double, frameRate: String
    ) -> (frames: Int, shortfallAllowance: Int) {
        let fps = ConformEngine.frameRateValue(frameRate) ?? 25
        let interval = 1 / fps
        let budget = trimmedSlotBudget(range: range, index: index, zones: zones,
                                       fps: fps, containerStart: containerStart)
        guard range.upperBound == index.count else { return (budget, 0) }
        let spanStart = index.pts[range.lowerBound] - containerStart
        let spanEnd = segmentEndTime(range: range, index: index, frameDuration: interval)
            - containerStart
        // The windows the select drops, in span time (head-clamped like the builder).
        let windows = zones.map { zone in
            (start: max(zone.start - interval / 4, spanStart + interval * 0.75),
             end: zone.end + interval / 4)
        }
        // Trailing uncertainty exists only when a window covers the final slot.
        guard let trailing = windows.filter({ $0.end >= spanEnd - interval }).map(\.start).min()
        else { return (budget, 0) }
        // The last index frame outside every window is guaranteed to decode and be
        // kept, anchoring the fill at least that deep.
        var lastKept = spanStart
        for i in range {
            let t = index.pts[i] - containerStart
            if t < trailing, !windows.contains(where: { t >= $0.start && t <= $0.end }) {
                lastKept = max(lastKept, t)
            }
        }
        let guaranteed = Int(((lastKept - spanStart) * fps).rounded()) + 1
        return (budget, max(0, budget - guaranteed))
    }

    /// Where a repaired segment's content ends in absolute presentation time: the next
    /// frame's pts, or one frame past the last when the span runs to the file end.
    private static func segmentEndTime(range: Range<Int>, index: FrameIndex,
                                       frameDuration: Double) -> Double {
        range.upperBound < index.count
            ? index.pts[range.upperBound]
            : (index.pts.last ?? 0) + frameDuration
    }

    /// The repaired span's output slot count: duration × fps, rounded.
    private static func slotBudget(range: Range<Int>, index: FrameIndex, fps: Double) -> Int {
        let start = index.pts[range.lowerBound]
        let end = segmentEndTime(range: range, index: index, frameDuration: 1 / fps)
        return max(1, Int(((end - start) * fps).rounded()))
    }

    /// The decode anchor for a repaired span: one keyframe before the keyframe at/or
    /// before the span start — two on MPEG-PS, whose byte-estimated `-ss` lands late
    /// (#43 de-risk; the detector seeks the same margin). Never past the file head.
    private static func repairAnchor(source: URL, range: Range<Int>, index: FrameIndex) -> Int {
        let psExtensions = ["mpg", "mpeg", "vob"]
        let back = psExtensions.contains(source.pathExtension.lowercased()) ? 2 : 1
        // No keyframe at/before the span start → fall back to the file head (frame 0);
        // stepping back further keyframes then just stays there (`max(0, …)`).
        var anchor = index.keyframeIndex(atOrBefore: range.lowerBound) ?? 0
        for _ in 0..<back {
            anchor = index.keyframeIndex(atOrBefore: max(0, anchor - 1)) ?? 0
        }
        return anchor
    }

    /// ffmpeg args producing the **timescale probe piece** (issue #18): one stream-copied
    /// video packet muxed into MP4, whose track timescale is then read back as the value
    /// the clip's real copy pieces will carry. Measured, never derived from the source:
    /// the mp4 muxer auto-raises an MKV's coarse 1/1000 stream timebase to 1/16000 on
    /// copy (verified in the shell), so the source's own probed timebase is not the answer.
    static func timescaleProbeArguments(source: URL, output: URL) -> [String] {
        ["-v", "error", "-i", source.path, "-map", "0:v:0",
         "-c", "copy", "-frames:v", "1", output.path]
    }

    /// The MP4 track timescale a re-encoded piece must pin (issue #18), from the timescale
    /// probe piece's `time_base` ("1/16000" ⇒ 16000; ffprobe's csv writer leaves a trailing
    /// comma on MPEG-2 streams, so commas are stripped). Only a unit-numerator timebase
    /// maps to a track timescale; anything else returns `nil` and the flag is omitted
    /// rather than guessed (the export then behaves exactly as before #18).
    static func trackTimescale(timeBase: String?) -> Int? {
        let cleaned = (timeBase ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ", \n"))
        let parts = cleaned.split(separator: "/")
        guard parts.count == 2, parts[0] == "1",
              let den = Int(parts[1]), den > 0 else { return nil }
        return den
    }

    // MARK: - Bounded keyframe copy (#52)

    /// How a copy segment's bit-exact span reaches its piece file.
    enum CopyStrategy {
        /// The segment-muxer cut at start_time-corrected DTS midpoints, **no input seek**
        /// (`ExportEngine.cutArguments`/`remuxArguments` via `copySegmentPlan`). This is
        /// the proven Milestone 1/2 cut/join path: it reads the source from frame 0 to the
        /// span's end (`-t`, #107) and writes the pre-in-cut head as a discarded segment.
        /// One or two copy spans per clip is fine; a whole-file repair plan's ~9 copy spans
        /// would each re-read the file from 0, still re-reading most of it ~9 times
        /// (~150 GB churn on a 4.8 h capture unbounded — the #52 finding).
        case segmentMux
        /// The bounded, input-seek, keyframe-to-keyframe copy (`boundedCopyArguments`): it
        /// seeks straight to the span's first frame and reads only the span. Frame-exact on
        /// a whole-file repair plan because every copy boundary is a copy-safe keyframe by
        /// construction (proven frame-exact on the real 1844 capture, #51). Used by the
        /// Clip Doctor repair-only export (issue #52); the verify gate still backstops it.
        case boundedKeyframe
    }

    /// ffmpeg args for a **bounded, input-seek, keyframe-to-keyframe** stream copy of the
    /// copy span `[range.lowerBound, range.upperBound)` into the segment pattern, keeping
    /// segment `000` (issue #52). Seeks to the span's first frame (`-ss`, start_time-
    /// relative like every other input seek — ffmpeg subtracts the container start_time),
    /// stream-copies, and forces a single split after exactly `hi − lo` frames so segment
    /// `000` is exactly the span. `-t span + margin` bounds the read a couple of seconds
    /// past the span so ffmpeg stops near the split instead of decoding to EOF — the whole
    /// point versus the segment-muxer path. Frame-exact on a repair plan: the span's first
    /// frame is a copy-safe keyframe the seek lands on, and the split frame is the next
    /// copy-safe keyframe (proven produced == planned on the real 1844 capture, #51).
    /// `segmentPattern` must carry a `%03d`; the wanted piece is always `…000.<ext>`.
    static func boundedCopyArguments(
        source: URL, range: Range<Int>, index: FrameIndex, containerStart: Double,
        segmentPattern: String
    ) -> [String] {
        let lo = range.lowerBound, hi = range.upperBound
        let seek = max(0, index.pts[lo] - containerStart)
        let spanEnd = hi < index.pts.count ? index.pts[hi] : (index.pts.last ?? index.pts[lo])
        let span = max(0, spanEnd - index.pts[lo])
        var args = ["-v", "error", "-ss", ExportEngine.timeString(seek), "-i", source.path]
        args += ["-map", "0:v:0", "-c", "copy", "-f", "segment"]
        args += ["-segment_frames", String(hi - lo), "-reset_timestamps", "1"]
        args += ["-t", ExportEngine.timeString(span + 2.0), segmentPattern]
        return args
    }

    /// How much output one segment-muxer copy run is expected to produce, for smoothing
    /// the progress bar by ffmpeg's `out_time` (issue #9). The run writes discarded
    /// segments as well as the wanted piece, so it is the *read* that sets the length: an
    /// out-cut bounds it at the cut plus the read margin (`ExportEngine.cutArguments`,
    /// issue #107), and without one it runs to EOF. Never past the source span — an
    /// out-cut close to EOF stops there — and `nil` when the span couldn't be measured.
    ///
    /// A head seek (issue #108) also moves where the read *begins*, and `out_time` restarts
    /// at the landing, so both ends shift by `origin` and the expectation is the read's true
    /// length — which is the whole point of the seek: on a clip 150 min into a 4h36 capture
    /// the bar now tracks ~60 s of read instead of ~9000 s.
    static func segmentMuxExpectedSeconds(plan: SegmentPlan, sourceSpan: Double?,
                                          headSeek: ExportEngine.CopyHeadSeek? = nil) -> Double? {
        let origin = headSeek?.origin ?? 0
        guard let out = plan.outSegmentTime else { return sourceSpan.map { $0 - origin } }
        let bounded = out + ExportEngine.copyReadMargin
        return (sourceSpan.map { min(bounded, $0) } ?? bounded) - origin
    }

    /// ffmpeg args for the one-packet **landing probe** behind a copy's head seek (issue
    /// #108): seek, stream-copy a single video packet, stop. `-copyts` is what makes the
    /// answer usable — the packet keeps its source timestamp, so the landing can be read off
    /// in the source's own terms rather than on whatever rebased timeline the real run picks.
    /// (The real run deliberately *omits* `-copyts`: it zeroes ffmpeg's `out_time` reporting,
    /// which the progress bar reads, and it isn't needed there because the offset cancels.)
    ///
    /// NUT is the piece container because it stores timestamps at full precision; Matroska
    /// would round the landing to a millisecond. A failed probe is not an error — the caller
    /// falls back to the unseeked read.
    static func landingProbeArguments(source: URL, seek: Double, output: URL) -> [String] {
        ["-v", "error",
         "-ss", ExportEngine.timeString(seek), "-copyts",
         "-i", source.path, "-map", "0:v:0", "-c", "copy", "-frames:v", "1",
         "-f", "nut", output.path]
    }

    /// Measures where an input seek would land so a copy segment can skip its pre-in-cut
    /// head (issue #108). Picks the anchor keyframe (`ExportEngine.copyHeadSeekTarget`),
    /// runs the probe down the same seek code path the real cut will take, and reports the
    /// landing on the index's axis.
    ///
    /// `nil` — read from frame 0, exactly as before — whenever the seek can't be shown to be
    /// safe: no head to skip, the probe failed (an ffmpeg without the NUT muxer included),
    /// or the landing is not strictly before the in-cut. That last guard is what protects
    /// `ExportEngine.wantedSegmentIndex`: a landing at or past the cut leaves the muxer no
    /// packets for segment `000`, which it then never writes, and the wanted piece would
    /// silently become `000` instead of `001`.
    static func copyHeadSeek(
        _ ffmpeg: URL, source: URL, plan: SegmentPlan, index: FrameIndex,
        containerStart: Double, probeOutput: URL
    ) async -> ExportEngine.CopyHeadSeek? {
        guard let inCut = plan.inSegmentTime,
              let seek = ExportEngine.copyHeadSeekTarget(
                  plan: plan, index: index, containerStart: containerStart),
              let startOffset = index.pts.first
        else { return nil }
        defer { try? FileManager.default.removeItem(at: probeOutput) }
        guard let result = try? await ProcessRunner.run(
                  ffmpeg, landingProbeArguments(source: source, seek: seek, output: probeOutput)),
              result.status == 0,
              let probed = try? await FrameIndexer.buildIndex(url: probeOutput),
              let landing = probed.pts.first
        else { return nil }
        let origin = landing - startOffset
        guard origin < inCut else { return nil }
        return ExportEngine.CopyHeadSeek(seek: seek, origin: origin)
    }

    /// Maps a copy segment `[copyRange.lowerBound, copyRange.upperBound)` onto a
    /// `SegmentPlan` so its validated segment-muxer cut/remux can stream-copy the span
    /// bit-exact. A bound that is a clip boundary (frame 0 / no out-cut keyframe) gets no
    /// cut at that end — copy from the file start / to the file end — and a span touching
    /// neither boundary becomes a two-cut plan whose wanted piece is the middle. The cut
    /// times are start_time-corrected DTS midpoints (ADR-0008).
    ///
    /// The out-cut anchors at the plan's `outCutKeyframe`, not the range's upper bound:
    /// on an open-GOP end the range stops `n_leading` frames before the keyframe (#16),
    /// but it is still the cut before the *keyframe's* DTS that produces it — the
    /// keyframe's leading pictures land in the discarded segment.
    static func copySegmentPlan(
        copyRange: Range<Int>, outCutKeyframe: Int?, index: FrameIndex
    ) -> SegmentPlan {
        let needsInCut = copyRange.lowerBound > 0
        return SegmentPlan(
            inFrame: copyRange.lowerBound,
            outFrame: copyRange.upperBound,
            inSegmentTime: needsInCut ? index.segmentTime(forCutAt: copyRange.lowerBound) : nil,
            outSegmentTime: outCutKeyframe.map { index.segmentTime(forCutAt: $0) }
        )
    }

    // MARK: - Orchestration

    /// Executes a Milestone 2 plan for one clip into a single **video** piece in `work`
    /// and returns it. Each re-encode segment is a frame-selected encode; each copy
    /// segment is M1's segment-muxer cut/remux; the pieces are concatenated in plan order
    /// (a single-segment plan needs no concat). Audio is rebuilt separately, as in M1.
    ///
    /// `onProgress` reports 0…1 across the clip's segment runs (issue #9), weighted by
    /// frame count and smoothed within each run by ffmpeg's out_time against the run's
    /// expected output: a re-encode produces its segment's span, while a segment-muxer
    /// cut (and a whole-clip remux) reads/writes the whole source span regardless of the
    /// wanted piece. The closing concat and verify aren't instrumented — the bar holds
    /// at the clip's top edge while they run.
    static func produceVideoPiece(
        _ ffmpeg: URL, source: URL, plan: [PlannedSegment], index: FrameIndex,
        encoder: [String], work: URL, ext: String, clipIndex: Int, displayName: String = "",
        codec: String? = nil,
        trackTimescale: Int? = nil, containerStart: Double = 0, frameRate: String? = nil,
        sourceDamaged: Bool = false, copyStrategy: CopyStrategy = .segmentMux,
        fieldCoded: Bool = false, reorderDepth: Int? = nil,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        guard !plan.isEmpty else { throw ExportError.invalidPlan }
        // Match the re-encoded pieces' reorder depth to the join they land in (ADR-0026):
        // every piece of a Matroska join has to agree on it, and this plan's *copy* pieces
        // carry the source's depth unchanged. The caller decides the depth — it sees the
        // whole join (`ExportEngine.pieceReorderDepth`); `nil` leaves the encoder args
        // exactly as passed (Clip Doctor's single-source repair, whose copy head already
        // declares the deepest depth in its own join).
        let encoder = reorderDepth.map {
            EncoderSelection.withEncoderParams(
                EncoderSelection.reorderDepthParams(depth: $0, forCodec: codec),
                in: encoder, forCodec: codec)
        } ?? encoder
        // A repaired segment needs the source rate for its fps fill and slot budget;
        // the planner only attaches damage when the rate parses, so this is a
        // can't-happen guard, not a policy. `repairRate` is read only by repaired
        // segments — the placeholder is never used (plans without damage don't read
        // it, and plans with damage threw above unless the real rate parsed).
        let parsedRate: String? = (frameRate.map { ConformEngine.frameRateValue($0) != nil } ?? false)
            ? frameRate : nil
        guard plan.allSatisfy({ $0.damage.isEmpty }) || parsedRate != nil else {
            throw ExportError.invalidPlan
        }
        let repairRate = parsedRate ?? "25/1"
        // Every copy piece carries its own parameter sets in-band (issue #113) so the join's
        // single container header can't decide how it decodes, plus — for mpeg2video→MKV
        // (issue #2) and any damaged *source*→MKV, whose truncated pictures choke the muxer
        // even from discarded segments (issue #47) — the missing-PTS refill.
        let damagedSource = sourceDamaged || plan.contains { !$0.damage.isEmpty }
        let bsf = ExportEngine.copyPieceBitstreamFilter(
            codec: codec, ext: ext, damaged: damagedSource)
        // The same refill's demuxer half (issue #116). An MPEG-PS anchor picture that lost
        // its PTS gets its true reordered one from `+genpts`; the `setts` fallback above
        // would put it `bf` frames early, on the previous anchor's PTS, and the finished
        // piece would then fail the verify decode though its pictures are correct.
        let copyInputFlags = ExportEngine.ptsRefillInputFlags(
            codec: codec, ext: ext, damaged: damagedSource)

        // The export-wide MP4 timescale (issue #24) stamps every piece — copies
        // included — so cross-clip joins can't stretch or collapse. Without one
        // (non-MP4 output, or a clip that couldn't be probed), an MP4 plan mixing
        // copy and re-encode pieces falls back to the per-clip pin (issue #18):
        // measure what the copy pieces will inherit via the one-packet timescale
        // probe and pin the re-encodes to it. An unreadable probe leaves the pin
        // off — the verify gates still backstop the seam.
        let copyTimescale: Int? = ext.lowercased() == "mp4" ? trackTimescale : nil
        var pieceTimescale: Int? = copyTimescale
        if pieceTimescale == nil,
           ext.lowercased() == "mp4",
           plan.contains(where: { $0.kind == .copy }),
           plan.contains(where: { $0.kind == .reEncode }) {
            let probe = work.appendingPathComponent("c\(clipIndex)_tsprobe.mp4")
            try await run(ffmpeg, timescaleProbeArguments(source: source, output: probe))
            pieceTimescale = Self.trackTimescale(timeBase: await MediaProbe.videoTimeBase(url: probe))
        }

        let segmentFrames = plan.map { $0.range.count }
        let interval = meanFrameInterval(index)
        let sourceSpan = interval.flatMap { i in
            index.pts.last.map { $0 - index.pts[0] + i }
        }

        var pieces: [URL] = []
        for (s, segment) in plan.enumerated() {
            // A segment-muxer copy's plan and head seek are settled before the run, because
            // the progress bar's expectation depends on them: the seek is what decides how
            // much of the source this run reads at all (issue #108).
            let copyPlan: SegmentPlan? = segment.kind == .copy && copyStrategy == .segmentMux
                ? copySegmentPlan(copyRange: segment.range,
                                  outCutKeyframe: segment.outCutKeyframe, index: index)
                : nil
            var headSeek: ExportEngine.CopyHeadSeek?
            if let copyPlan, ExportEngine.needsCut(copyPlan) {
                headSeek = await Self.copyHeadSeek(
                    ffmpeg, source: source, plan: copyPlan, index: index,
                    containerStart: containerStart,
                    probeOutput: work.appendingPathComponent("c\(clipIndex)_s\(s)_seek.nut"))
            }
            let expected: Double?
            switch segment.kind {
            case .reEncode: expected = interval.map { Double(segment.range.count) * $0 }
            case .copy:
                switch copyStrategy {
                // The segment-muxer cut reads from its head seek (or frame 0 without one,
                // #108) to its out-cut plus the read margin (#107), or to EOF when it has no
                // out-cut; the bounded copy reads only its own span (#52). The bar tracks
                // whichever read this run does.
                case .segmentMux:
                    expected = copyPlan.flatMap {
                        segmentMuxExpectedSeconds(plan: $0, sourceSpan: sourceSpan,
                                                  headSeek: headSeek)
                    }
                case .boundedKeyframe:
                    let lo = segment.range.lowerBound, hi = segment.range.upperBound
                    expected = (lo < index.pts.count && hi < index.pts.count)
                        ? index.pts[hi] - index.pts[lo] : sourceSpan
                }
            }
            let onOutTime: @Sendable (Double) -> Void = { t in
                onProgress(ExportProgress.withinClip(
                    segmentFrames: segmentFrames, completedSegments: s,
                    currentRunFraction: ExportProgress.runFraction(outTime: t, expectedSeconds: expected)))
            }
            let piece: URL
            switch segment.kind {
            case .reEncode where !segment.damage.isEmpty:
                piece = work.appendingPathComponent("c\(clipIndex)_s\(s)_rep.\(ext)")
                try await run(ffmpeg, repairedSegmentArguments(
                    source: source, range: segment.range, index: index,
                    zones: segment.damage, containerStart: containerStart,
                    frameRate: repairRate, encoder: encoder, output: piece,
                    trackTimescale: pieceTimescale),
                    onOutTime: onOutTime)
            case .reEncode:
                piece = work.appendingPathComponent("c\(clipIndex)_s\(s)_re.\(ext)")
                try await run(ffmpeg, reencodeSegmentArguments(
                    source: source, range: segment.range, index: index,
                    encoder: encoder, output: piece, trackTimescale: pieceTimescale),
                    onOutTime: onOutTime)
            case .copy where copyStrategy == .boundedKeyframe:
                // Whole-file repair (#52): seek straight to the span and copy only it.
                // The span is keyframe-bounded by construction, so segment 000 is exactly
                // the range — no DTS-midpoint cut, no discarded full-file read.
                let pattern = work.appendingPathComponent("c\(clipIndex)_s\(s)_cp_%03d.\(ext)").path
                try await run(ffmpeg, boundedCopyArguments(
                    source: source, range: segment.range, index: index,
                    containerStart: containerStart, segmentPattern: pattern), onOutTime: onOutTime)
                piece = work.appendingPathComponent(String(
                    format: "c\(clipIndex)_s\(s)_cp_%03d.\(ext)", 0))
            case .copy:
                // `copyPlan` is non-nil for every `.segmentMux` copy — settled above so the
                // head seek could be measured before the progress expectation was formed.
                let copyPlan = copyPlan ?? copySegmentPlan(
                    copyRange: segment.range, outCutKeyframe: segment.outCutKeyframe, index: index)
                if ExportEngine.needsCut(copyPlan) {
                    let pattern = work.appendingPathComponent("c\(clipIndex)_s\(s)_cp_%03d.\(ext)").path
                    try await run(ffmpeg, ExportEngine.cutArguments(
                        source: source, plan: copyPlan, segmentPattern: pattern,
                        bitstreamFilter: bsf, trackTimescale: copyTimescale,
                        headSeek: headSeek, inputFlags: copyInputFlags), onOutTime: onOutTime)
                    piece = work.appendingPathComponent(String(
                        format: "c\(clipIndex)_s\(s)_cp_%03d.\(ext)",
                        ExportEngine.wantedSegmentIndex(plan: copyPlan)))
                    // The muxer's other segments are dead the moment the run ends — no
                    // concat list ever names them. With a head seek that is a couple of
                    // GOPs, but a run that fell back to reading from zero leaves the whole
                    // pre-clip head, and holding those to the end of the export is what set
                    // the 43 GB peak (issue #108). Drop them now, not on the export's exit.
                    discardDeadSegments(prefix: "c\(clipIndex)_s\(s)_cp_", keeping: piece, in: work)
                } else {
                    piece = work.appendingPathComponent("c\(clipIndex)_s\(s)_cp.\(ext)")
                    try await run(ffmpeg, ExportEngine.remuxArguments(
                        source: source, output: piece, bitstreamFilter: bsf,
                        trackTimescale: copyTimescale, inputFlags: copyInputFlags),
                                  onOutTime: onOutTime)
                }
            }
            guard FileManager.default.fileExists(atPath: piece.path) else {
                throw ExportError.missingSegment
            }
            pieces.append(piece)
            onProgress(ExportProgress.withinClip(
                segmentFrames: segmentFrames, completedSegments: s + 1, currentRunFraction: 0))
        }

        let result: URL
        if pieces.count == 1 {
            result = pieces[0]
        } else {
            let joined = work.appendingPathComponent("c\(clipIndex)_joined.\(ext)")
            let listFile = work.appendingPathComponent("c\(clipIndex)_concat.txt")
            // The seam-closing duration directive is `pts[hi] − pts[lo]`, exact only when
            // the index is presentation-ordered and uniform. A field-coded (PAFF) copy
            // head's field packets are reorder-interleaved with sub-frame PTS, so that
            // span over-estimates the head's true display duration and the directive opens
            // a gap at the copy→MBAFF seam (the re-scan then reads the gap as damage). The
            // PAFF copy head is reset-timestamp and its container duration *is* its true
            // span, so omit the directive and let the demuxer place the tail on it.
            let durations = fieldCoded ? [] : segmentSpans(plan, index: index)
            try ExportEngine.concatListContents(pieces: pieces, durations: durations)
                .write(to: listFile, atomically: true, encoding: .utf8)
            try await run(ffmpeg, ExportEngine.concatArguments(listFile: listFile, output: joined))
            result = joined
        }
        // A field-coded (PAFF) damage-to-EOF piece (issue #54) can't go through the
        // standard gate: its frame count mixes the PAFF copy head (2 field packets per
        // displayed frame) with the MBAFF tail (1 packet per frame), and the head's 0.02 s
        // field cadence reads as duplicates against the tail's 0.04 s median in
        // `timestampDefect` — both false-fail. The decode check is the one that catches
        // what matters here (a corrupt copy→MBAFF entry seam), so that is the whole gate;
        // duration and zero-zones are confirmed by the engine's post-mux re-scan.
        let location = VerificationLocation(
            clipIndex: clipIndex, displayName: displayName,
            piece: result.lastPathComponent, plan: plan)
        if fieldCoded {
            try await verifyFieldCodedPiece(ffmpeg, result, at: location)
            return result
        }
        // Per-segment expected output counts: a copy or plain re-encode produces
        // exactly its frame range; a repaired segment produces its slot budget
        // (duration × fps), short only inside an EOF damage window (issue #47).
        var outputCounts: [Int] = []
        var shortfallAllowance = 0
        for segment in plan {
            if segment.damage.isEmpty {
                outputCounts.append(segment.range.count)
            } else {
                let expectation = repairedSegmentExpectation(
                    range: segment.range, index: index, zones: segment.damage,
                    containerStart: containerStart, frameRate: repairRate)
                outputCounts.append(expectation.frames)
                shortfallAllowance += expectation.shortfallAllowance
            }
        }
        try await verifyPiece(ffmpeg, result, expectedCounts: outputCounts,
                              shortfallAllowance: shortfallAllowance,
                              sourceDamaged: sourceDamaged,
                              plan: plan, sourcePts: index.pts, at: location)
        return result
    }

    /// The video frame count a produced piece must have: the planned segments tile the kept
    /// presentation range contiguously, so it is their combined length. `verifyPiece` checks
    /// the real output against this (ADR-0008 verifies by frame count, never by reading the
    /// reset output timestamps).
    static func expectedFrameCount(_ plan: [PlannedSegment]) -> Int {
        plan.reduce(0) { $0 + $1.range.count }
    }

    /// The timeline span (seconds) each planned segment should occupy when its pieces are
    /// concatenated — the `duration` directive fed to `ExportEngine.concatListContents` to
    /// close the start_time seam gap. A segment `[lo, hi)` spans from its first kept frame to
    /// the *next* segment's first frame, i.e. `pts[hi] - pts[lo]`: an exact presentation-time
    /// offset (no frame-rate estimate, so the demuxer can't truncate the piece). The segments
    /// tile contiguously, so for every segment but the last `hi` is the next segment's start —
    /// a real, in-bounds frame index. The final segment may run to the clip end (`hi ==
    /// count`, where `pts[hi]` would be out of bounds); its span never offsets anything, so it
    /// is left `nil` (no directive). Returns one entry per segment, aligned to the pieces.
    static func segmentSpans(_ plan: [PlannedSegment], index: FrameIndex) -> [Double?] {
        plan.map { seg in
            let lo = seg.range.lowerBound, hi = seg.range.upperBound
            guard lo < index.pts.count, hi < index.pts.count else { return nil }
            return index.pts[hi] - index.pts[lo]
        }
    }

    /// The **verify windows** a finished piece's decode gate is bounded to (ADR-0030, issue
    /// #114): one keyframe-anchored span per re-encoded segment, in the piece's own reset
    /// timeline. Pure over the plan and the piece's own index, so every plan shape is
    /// unit-tested without ffmpeg.
    ///
    /// Each re-encoded segment gets a window that covers **both of its seams plus a copied
    /// GOP on each side**, because every failure the decode can catch is seam-local — an
    /// orphaned leading picture at a re-encode↔copy seam, a retained RASL, a bad copy→MBAFF
    /// entry, or the parameter-set mismatch of commit 8bacae6, which shows on the frames of
    /// whichever piece does not own the join's single container header:
    ///
    /// - **start** — the nearest **copy-safe** keyframe at or before the last keyframe
    ///   strictly before the seam, searched only inside the preceding copy segment. None →
    ///   that copy segment's own start, which is copy-safe by construction — and the piece
    ///   start if a plan ever hands over a copy that does not begin on a keyframe. No
    ///   preceding copy segment → the piece start. It is never merely *a* keyframe: entering a decode at an
    ///   open-GOP keyframe orphans its leading pictures, and the flood that produces is
    ///   indistinguishable from the defect this gate exists to refuse (ADR-0030 step 5).
    /// - **end** — the **second** keyframe of the following copy segment, so one whole copied
    ///   GOP after the seam is decoded. No following copy segment → the piece end.
    ///
    /// A copy-only plan gets one window from the piece start to its second keyframe: the cut
    /// start is its only seam. Windows sort and merge. **`nil` means "decode the whole
    /// piece"** — a plan whose windows cover it, a piece too short to bound, an empty or
    /// mismatched input. `pieceSpan` is the piece's own first…last presentation time, which
    /// the keyframe map alone cannot give (a piece rarely ends on a keyframe).
    static func verifyWindows(
        plan: [PlannedSegment], outputCounts: [Int],
        pieceKeyframePts: [Int: Double], pieceCopySafeFlags: [Int: Bool],
        pieceSpan: ClosedRange<Double>
    ) -> [ClosedRange<Double>]? {
        guard !plan.isEmpty, plan.count == outputCounts.count,
              pieceSpan.upperBound > pieceSpan.lowerBound else { return nil }
        var segmentStarts: [Int] = []
        var offset = 0
        for count in outputCounts { segmentStarts.append(offset); offset += count }
        let total = offset
        let keyframes = pieceKeyframePts.keys.sorted()

        func secondKeyframe(from lo: Int, below hi: Int) -> Double? {
            let inside = keyframes.filter { $0 >= lo && $0 < hi }
            return inside.count > 1 ? pieceKeyframePts[inside[1]] : nil
        }
        func windowStart(before seam: Int, inCopyFrom copyStart: Int) -> Double {
            // The last keyframe before the seam opens the final copied GOP; the window has to
            // start at a copy-safe keyframe at or before it, or not be placed at all.
            guard let lastBefore = keyframes.last(where: { $0 < seam && $0 >= copyStart }),
                  let safe = keyframes.last(where: {
                      $0 <= lastBefore && $0 >= copyStart && pieceCopySafeFlags[$0] == true
                  }), let pts = pieceKeyframePts[safe]
            else { return pieceKeyframePts[copyStart] ?? pieceSpan.lowerBound }
            return pts
        }

        var windows: [ClosedRange<Double>] = []
        guard plan.contains(where: { $0.kind == .reEncode }) else {
            let end = secondKeyframe(from: 0, below: total) ?? pieceSpan.upperBound
            windows.append(pieceSpan.lowerBound...max(end, pieceSpan.lowerBound))
            return merged(windows, in: pieceSpan)
        }
        for (i, segment) in plan.enumerated() where segment.kind == .reEncode {
            let seam = segmentStarts[i]
            let start = (i > 0 && plan[i - 1].kind == .copy)
                ? windowStart(before: seam, inCopyFrom: segmentStarts[i - 1])
                : pieceSpan.lowerBound
            let end: Double
            if i + 1 < plan.count, plan[i + 1].kind == .copy {
                let next = segmentStarts[i + 1]
                end = secondKeyframe(from: next, below: next + outputCounts[i + 1])
                    ?? pieceSpan.upperBound
            } else {
                end = pieceSpan.upperBound
            }
            windows.append(min(start, end)...max(start, end))
        }
        return merged(windows, in: pieceSpan)
    }

    /// Overlapping windows joined into one, and `nil` when what is left covers the piece —
    /// the plan shapes that have nothing to save (a tiny piece, a plan whose seams sit within
    /// one copied GOP of each other) say so by asking for the whole-piece decode.
    private static func merged(_ windows: [ClosedRange<Double>],
                               in span: ClosedRange<Double>) -> [ClosedRange<Double>]? {
        var joined: [ClosedRange<Double>] = []
        for window in windows.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = joined.last, window.lowerBound <= last.upperBound {
                joined[joined.count - 1] = last.lowerBound...max(last.upperBound, window.upperBound)
            } else {
                joined.append(window)
            }
        }
        guard let only = joined.first, joined.count > 1
                || only.lowerBound > span.lowerBound || only.upperBound < span.upperBound
        else { return nil }
        return joined
    }

    /// Verifies a produced video piece before it ships (ADR-0008). Three checks, any of
    /// which throws rather than letting a silently-wrong cut through:
    ///   1. Frame count — the output's video packet count must equal the planned total
    ///      (per-segment expected counts; a repaired segment expects its slot budget,
    ///      short only within `shortfallAllowance` at an EOF damage window — issue #47),
    ///      catching any frame leaking past a cut (a desynced index once made a 2-clip
    ///      export come out +10 frames).
    ///   2. Decode check — a full `-xerror` decode pass must succeed, catching a corrupt
    ///      re-encode→copy seam (e.g. orphaned leading pictures) that a frame count alone
    ///      would miss.
    ///   3. Timestamp check — the output's presentation timestamps must be free of the seam
    ///      gap (start_time concat offset) and duplicates (B-pyramid/MKV collapse) that the
    ///      frame count and decode would both pass over. Re-encoded spans, seams, and
    ///      segment-edge windows are held to uniform spacing; a copied span is held to the
    ///      *source's* timestamp pattern instead — a faithful copy of an irregular source
    ///      is correct output, not a defect (issue #19, plan-aware
    ///      `ExportEngine.timestampDefect`).
    /// A full `-xerror` decode pass from the piece's start to EOF — the one check shared by
    /// `verifyPiece` (run before its frame-count/timestamp gates) and `verifyFieldCodedPiece`
    /// (its whole gate). It catches a corrupt seam (e.g. orphaned leading pictures, or a bad
    /// copy→MBAFF entry) that a frame count alone would pass over. A damaged source's piece
    /// decodes with a per-frame warning flood even at `-v error`; `ProcessRunner` drains
    /// stderr live into a bounded tail (issue #59), so the `-f null -` pass no longer backs up
    /// the OS pipe and deadlocks at 0% CPU on a multi-hour repair — the failure detail is the
    /// tail's final fatal lines. The thrown message opens with `location`'s line (issue #113),
    /// then `failureLabel`, so each refusal names both where it happened and what failed
    /// (a cut vs the repaired video).
    ///
    /// **`requireSilentDecode` is what gives this check teeth** (issue #113). The exit status
    /// alone is nearly blind: a video decoder conceals what it cannot parse and returns
    /// success, so `-xerror` exits 0 on a piece whose every frame came out as colour garbage —
    /// measured at exit 0 on a 6002-frame render with 2150 decode-error lines. What the
    /// decoder *says* is the real signal, so on a clean source the pass must also be silent.
    /// A damaged source is exempt: its piece legitimately prints a per-frame flood (the whole
    /// point of the repair is that the source doesn't decode), and there the exit status is
    /// all this check can honestly assert.
    ///
    /// `windows` bounds the pass to the seams (ADR-0030): one decode per **verify window**
    /// instead of one over the whole piece, which on the 8-clip round job of the 2026-09-15
    /// review was 06:16 of a 15:36 wall clock, nearly all of it decoding stream-copied frames
    /// no cut had touched. `nil` — the field-coded caller, a piece too short to bound, a plan
    /// whose windows merge to cover it — is the whole-piece pass, unchanged. The bound never
    /// costs the gate teeth: a window that cannot be entered on a copy-safe keyframe, or that
    /// comes back with anything to say, falls through to the whole-piece pass, and *that* is
    /// the verdict (`boundedDecodePassed`).
    /// Internal rather than private so `BoundedVerifyIntegrationTests` can run the two
    /// decodes side by side on one piece and compare their verdicts (issue #114).
    static func decodeCheck(_ ffmpeg: URL, _ piece: URL, failureLabel: String,
                                   requireSilentDecode: Bool,
                                   at location: VerificationLocation,
                                   windows: [ClosedRange<Double>]? = nil,
                                   pieceStart: Double = 0,
                                   copySafeKeyframePts: [Double] = []) async throws {
        if let windows, !windows.isEmpty,
           try await boundedDecodePassed(
               ffmpeg, piece, windows: windows, pieceStart: pieceStart,
               copySafeKeyframePts: copySafeKeyframePts,
               requireSilentDecode: requireSilentDecode) {
            return
        }
        let decode = try await ProcessRunner.run(
            ffmpeg, ["-v", "error", "-xerror", "-i", piece.path, "-f", "null", "-"])
        let complaints = String(data: decode.stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard decode.status == 0 else {
            throw ExportError.verificationFailed(location.message(
                failureLabel,
                detail: complaints.isEmpty ? "decode exited \(decode.status)" : complaints))
        }
        guard !requireSilentDecode || complaints.isEmpty else {
            throw ExportError.verificationFailed(location.message(failureLabel, detail: complaints))
        }
    }

    /// How close two presentation times must be to count as the same one — well under a
    /// frame at any rate this app handles, and above the millisecond a Matroska timestamp
    /// rounds to.
    static let seekTolerance = 0.001

    /// Runs the bounded verify decode over `windows` and reports whether it **proved** the
    /// piece clean. `false` means "not proven here", never "defective": a window whose decode
    /// entry could not be measured onto a copy-safe keyframe, or that exited non-zero, or that
    /// spoke when silence was required. The caller then decodes the whole piece and that pass
    /// refuses or passes — so the bounded decode can only ever be as strict as the gate it
    /// shortens, and a new way for a seek to go wrong costs wall time, never teeth.
    ///
    /// A window starting at the piece's own first frame takes no seek at all; every other
    /// window's entry is **measured** (`seekLanding`), because `-ss <pts>` does not land where
    /// it is asked — Matroska lands one keyframe early (ffmpeg subtracts a version-dependent
    /// `dts_heuristic` of ≈ 0.13 s from a reordered stream's seek target), which is why the ask
    /// is corrected by `(target − landing)` and re-measured rather than nudged by a constant.
    /// The landing must be a copy-safe keyframe at or before the window start: entering at an
    /// open-GOP keyframe orphans its leading pictures, and the flood that produces is exactly
    /// what `requireSilentDecode` exists to catch elsewhere (measured on H.264: rc 183, and no
    /// frame decoded at all until the next IDR — ADR-0030 step 5).
    private static func boundedDecodePassed(
        _ ffmpeg: URL, _ piece: URL, windows: [ClosedRange<Double>], pieceStart: Double,
        copySafeKeyframePts: [Double], requireSilentDecode: Bool
    ) async throws -> Bool {
        for window in windows {
            var seekArgs: [String] = []
            var span = window.upperBound - pieceStart
            if window.lowerBound > pieceStart + seekTolerance {
                guard let entry = try await measuredEntry(
                    ffmpeg, piece, to: window.lowerBound, from: pieceStart,
                    copySafeKeyframePts: copySafeKeyframePts) else { return false }
                seekArgs = ["-ss", ExportEngine.timeString(entry.ask)]
                span = window.upperBound - entry.landing
            }
            guard span > 0 else { return false }
            let decode = try await ProcessRunner.run(
                ffmpeg, ["-v", "error", "-xerror"] + seekArgs + ["-i", piece.path]
                    + ["-t", ExportEngine.timeString(span), "-f", "null", "-"])
            let complaints = String(data: decode.stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard decode.status == 0, !requireSilentDecode || complaints.isEmpty else {
                return false
            }
        }
        return true
    }

    /// The `-ss` value that makes a decode enter `piece` at `target`, and where it measured
    /// the entry. `nil` when no ask lands on a copy-safe keyframe at or before `target` — on
    /// an H.264 or HEVC `.ts` piece that is every ask, because the mpegts demuxer seeks by
    /// byte position and hands the decoder whatever precedes the keyframe (ADR-0030 step 4).
    private static func measuredEntry(
        _ ffmpeg: URL, _ piece: URL, to target: Double, from pieceStart: Double,
        copySafeKeyframePts: [Double]
    ) async throws -> (ask: Double, landing: Double)? {
        var ask = target - pieceStart
        for _ in 0..<2 {
            guard let landing = try await seekLanding(ffmpeg, piece: piece, seek: ask) else {
                return nil
            }
            // Accept only a measured landing that is itself a copy-safe keyframe, at or before
            // the window start. Landing *earlier* than asked is fine — it decodes more of the
            // copied body, not less.
            if landing <= target + seekTolerance,
               copySafeKeyframePts.contains(where: { abs($0 - landing) <= seekTolerance }) {
                return (ask, landing)
            }
            ask += target - landing
            if ask < 0 { return nil }
        }
        return nil
    }

    /// Where an input seek really lands — the landing probe of ADR-0027, pointed at a finished
    /// piece instead of a source. One stream-copied packet, written as `framecrc` rather than
    /// into a container: the **mpegts muxer adds its own ~1.4 s base** to every timestamp it
    /// writes, so a probe muxed to `.ts` reports a landing 1.4 s late and a correction then
    /// walks the entry onto an open-GOP keyframe. It **copies, never decodes**, for the same
    /// reason: a decode reports the first frame the decoder could *recover*, which on H.264 is
    /// the next IDR — measured 4.78 s past the real landing. `nil` when the probe writes
    /// nothing readable, which the caller reads as "decode the whole piece".
    static func seekLanding(_ ffmpeg: URL, piece: URL, seek: Double) async throws -> Double? {
        let probe = try await ProcessRunner.run(ffmpeg, [
            "-v", "error", "-copyts", "-ss", ExportEngine.timeString(seek), "-i", piece.path,
            "-frames:v", "1", "-map", "0:v:0", "-c", "copy", "-f", "framecrc", "-"])
        guard probe.status == 0, let text = String(data: probe.stdout, encoding: .utf8) else {
            return nil
        }
        return framecrcFirstPts(text)
    }

    /// The first packet's presentation time from a `framecrc` dump: its `#tb <stream>: n/d`
    /// header gives the time base, and each row is `stream, dts, pts, duration, size, crc`.
    /// `nil` for a dump with no timed row — a probe that landed past the end, or a packet
    /// whose pts is `N/A`.
    static func framecrcFirstPts(_ text: String) -> Double? {
        var timeBase: Double?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("#tb ") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let ratio = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces).split(separator: "/")
                if ratio.count == 2, let n = Double(ratio[0]), let d = Double(ratio[1]), d != 0 {
                    timeBase = n / d
                }
            } else if !line.hasPrefix("#") {
                let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                guard fields.count > 2, let base = timeBase,
                      let ticks = Double(fields[2].trimmingCharacters(in: .whitespaces))
                else { return nil }
                return ticks * base
            }
        }
        return nil
    }

    /// Internal rather than private so `BoundedVerifyIntegrationTests` can point the gate at
    /// a piece built to be wrong — the executor refuses to produce one (issue #114).
    static func verifyPiece(_ ffmpeg: URL, _ piece: URL, expectedCounts: [Int],
                                    shortfallAllowance: Int = 0, sourceDamaged: Bool = false,
                                    plan: [PlannedSegment], sourcePts: [Double],
                                    at location: VerificationLocation) async throws {
        let expectedFrames = expectedCounts.reduce(0, +)
        let actual = try await FrameIndexer.frameCount(url: piece)
        guard actual <= expectedFrames, actual >= expectedFrames - shortfallAllowance else {
            throw ExportError.verificationFailed(location.message(
                "Produced \(actual) video frames but the cut kept \(expectedFrames)"
                + (shortfallAllowance > 0 ? " (−\(shortfallAllowance) allowed at the damaged file end)." : ".")))
        }
        // Any EOF shortfall lands in the trailing repaired segment — re-anchor the
        // timestamp mapping so the copy spans before it still line up.
        var outputCounts = expectedCounts
        if actual < expectedFrames,
           let last = plan.lastIndex(where: { !$0.damage.isEmpty }) {
            outputCounts[last] -= expectedFrames - actual
        }
        // The piece's own index, built once: it anchors the verify windows on the piece's
        // keyframes and is the timestamp gate's input either way (ADR-0030).
        let pieceIndex = try await FrameIndexer.buildIndex(url: piece)
        let pts = pieceIndex.pts
        let copySafe = CopySafeBoundaryDetector.copySafeFlags(
            keyframeFlags: pieceIndex.keyframeFlags, dts: pieceIndex.dts)
        var keyframePts: [Int: Double] = [:]
        var copySafeFlags: [Int: Bool] = [:]
        for i in pieceIndex.keyframeFlags.indices where pieceIndex.keyframeFlags[i] {
            keyframePts[i] = pts[i]
            copySafeFlags[i] = i < copySafe.count && copySafe[i]
        }
        let span = (pts.first ?? 0)...(pts.last ?? 0)
        let windows = verifyWindows(plan: plan, outputCounts: outputCounts,
                                    pieceKeyframePts: keyframePts,
                                    pieceCopySafeFlags: copySafeFlags, pieceSpan: span)
        try await decodeCheck(ffmpeg, piece, failureLabel: "A decode check failed on the cut.",
                              requireSilentDecode: !sourceDamaged
                                  && plan.allSatisfy { $0.damage.isEmpty },
                              at: location,
                              windows: windows, pieceStart: span.lowerBound,
                              copySafeKeyframePts: keyframePts.compactMap {
                                  copySafeFlags[$0.key] == true ? $0.value : nil
                              }.sorted())
        if let reason = ExportEngine.timestampDefect(pts: pts, plan: plan, sourcePts: sourcePts,
                                                     outputCounts: outputCounts) {
            throw ExportError.verificationFailed(location.message(
                "The cut produced irregular timestamps: \(reason)"))
        }
    }

    /// Verifies a **field-coded (PAFF) damage-to-EOF** piece before it ships (issue #54).
    /// Just the decode check from `verifyPiece` — a full `-xerror` decode pass from start
    /// to EOF, which catches the one failure mode this repair can have: a corrupt
    /// copy→MBAFF entry seam (the proven-impossible resume seam can't occur, there is only
    /// the one entry transition). The frame-count and timestamp checks are deliberately
    /// dropped: a PAFF copy head packs two field packets per displayed frame while the
    /// MBAFF tail packs one, so neither the packet count nor the head's 0.02 s field
    /// cadence reconciles with the tail under `verifyPiece`'s display-frame accounting —
    /// both would false-fail a correct piece. The "non monotonically increasing dts to
    /// muxer" line the null muxer prints on field-coded rescale is benign (exit 0,
    /// de-risked); real DTS is monotonic once muxed to the container. Duration preservation
    /// and a zero-zones verdict are confirmed by the engine's post-mux re-scan.
    ///
    /// The exit status is also all this gate can assert (`requireSilentDecode: false`): the
    /// repair exists because the source is damaged, so a per-frame decoder flood is the
    /// expected output, and the null muxer's benign "non monotonically increasing dts to
    /// muxer" line on field-coded rescale would fail a silence requirement on a correct piece.
    private static func verifyFieldCodedPiece(_ ffmpeg: URL, _ piece: URL,
                                              at location: VerificationLocation) async throws {
        try await decodeCheck(ffmpeg, piece, failureLabel: "A decode check failed on the repaired video.",
                              requireSilentDecode: false, at: location)
    }

    /// The clip's mean frame interval in seconds — exact under CFR; a timestamp-dirty
    /// source's stray dup/gap anomalies (issue #19) wash out over the average. Only
    /// feeds progress estimation. `nil` below two frames.
    private static func meanFrameInterval(_ index: FrameIndex) -> Double? {
        let pts = index.pts
        guard pts.count >= 2 else { return nil }
        return (pts[pts.count - 1] - pts[0]) / Double(pts.count - 1)
    }

    /// Removes the segments one copy run produced and no one keeps — everything sharing the
    /// run's `c<clip>_s<segment>_cp_` prefix except the wanted piece (issue #108). Best
    /// effort: a file that won't delete is left for the work directory's own teardown.
    static func discardDeadSegments(prefix: String, keeping piece: URL, in work: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: work.path) else { return }
        for name in names where name.hasPrefix(prefix) && name != piece.lastPathComponent {
            try? fm.removeItem(at: work.appendingPathComponent(name))
        }
    }

    /// Runs ffmpeg and turns a non-zero exit into a `cutFailed` with its stderr. With
    /// `onOutTime` the run also streams `-progress pipe:1` (issue #9), reporting each
    /// block's out_time seconds as it arrives.
    private static func run(_ ffmpeg: URL, _ args: [String],
                            onOutTime: (@Sendable (Double) -> Void)? = nil) async throws {
        let result: ProcessResult
        if let onOutTime {
            let parser = ProgressParser()
            result = try await ProcessRunner.run(ffmpeg, ExportProgress.progressArguments(args)) { chunk in
                if let t = parser.feed(chunk) { onOutTime(t) }
            }
        } else {
            result = try await ProcessRunner.run(ffmpeg, args)
        }
        guard result.status == 0 else {
            throw ExportError.cutFailed(String(data: result.stderr, encoding: .utf8) ?? "exit \(result.status)")
        }
    }
}
