import Foundation

/// One clip's contribution to an export: where it lives and the Milestone 2 plan of what
/// to keep (ADR-0009) — an ordered list of copy / re-encode `segments` over `index`,
/// produced with `encoder` (the source-matched re-encode args). `codec` is the ffprobe
/// `codec_name`, used to refuse a stream-copy concat across different codecs (that is
/// conform — a later milestone).
///
/// `audioStart`/`audioEnd` are the clip's kept range as **input-seek seconds** — measured
/// from the container's start_time, i.e. `pts − start_time` (`keptWindow`; issue #3) —
/// the audio is re-encoded over exactly this window so it stays aligned with the video
/// and the joins are gap-free (ADR-0008). `nil` means that end is the clip boundary (no
/// cut there).
struct ExportItem {
    var source: URL
    /// The clip's display name, used to name this clip's file in `.separate` mode
    /// (`NN <clip name>.<ext>`, issue #30).
    var displayName: String = ""
    var codec: String? = nil
    var segments: [PlannedSegment] = []
    var index: FrameIndex = FrameIndex(pts: [], keyframeFlags: [])
    var encoder: [String] = []
    /// The container's start_time — the base of every damage-zone time and input-seek
    /// second. Repaired segments (issue #47) need it to place their select windows;
    /// 0 for an undamaged plan, where nothing reads it.
    var containerStart: Double = 0
    /// The probed video frame rate ("25/1") — a repaired segment's fps fill and slot
    /// budget run at the source rate (issue #47). nil on undamaged plans.
    var frameRate: String? = nil
    /// Whether the clip's source has recorded damage zones at all — not just inside
    /// this plan's kept window. The MKV copy cut needs the pts refill whenever the
    /// *file* carries timestamp-less packets: the segment muxer writes the discarded
    /// segments too, so a clean kept window still chokes on damage elsewhere (the
    /// 1844 control-window failure, issue #47).
    var sourceDamaged: Bool = false
    /// Whether this clip is on the field-coded copy-cut route (issue #96): a confirmed
    /// field-coded (PAFF) H.264 source (`FieldCodedSupport.requiresCopyOnlyCuts`). When
    /// true the planner has already enforced that `segments` are **copy only**
    /// (`ExportError.fieldCodedPlanNotCopyOnly`) — the engine may rely on that and must
    /// use the field-coded execution recipe: the frame index counts *fields*, so any
    /// duration/frame arithmetic derived from it is 2× off for the whole-frame encoder
    /// (ADR-0022). `false` for every other clip; nothing reads it on the conform path.
    var fieldCoded: Bool = false
    /// The source stream's reorder depth (`VideoProperties.reorderDepth`) — how deeply its
    /// decode order is shuffled. Read only through `ExportEngine.joinReorderDepth`: this
    /// clip's *copy* pieces carry this depth unchanged, so it sets the bar the pieces the
    /// app encodes are matched to (ADR-0026). `nil` (unprobed, or a conformed clip, whose
    /// pieces are all fresh encodes) counts as the shallow 1.
    var sourceReorderDepth: Int? = nil
    var audioStart: Double? = nil
    var audioEnd: Double? = nil
    /// What feeds each of this clip's audio legs, by output track (ADR-0014): the clip's
    /// own Nth audio stream, an external file, or `nil` for silence. Output tracks past
    /// the end of this list are silence too.
    var audioSources: [ExportEngine.AudioSource?] = [.stream(0)]
    /// The channel-mix filter for each leg, by output track (ADR-0019) — nil for
    /// Original/no-op (and for every track past the end). Inserted before the leg's
    /// conform in the rebuild chain; never on a silence leg.
    var audioMixFilters: [String?] = []
    /// The clip's kept video duration in seconds — every audio leg is trimmed/padded to
    /// exactly this many samples so the output tracks can't drift apart at joins
    /// (ADR-0014). Falls back to `audioEnd - audioStart` when unset.
    var audioDuration: Double? = nil
    /// Set when this clip does not match the target and its video must be fully re-encoded to
    /// the target spec (ADR-0011). When present the clip is conformed instead of smart-rendered,
    /// and `segments` is unused; `nil` for a matching clip (the M2 smart-render path).
    var conform: ConformEngine.VideoConform? = nil
    /// Cut-only (ADR-0018): this clip's own output tracks — exactly its selected slots,
    /// each possibly carrying its own encoder — overriding the export-wide track list in
    /// `.separate` mode. `nil` (every other mode) means the export-wide tracks apply.
    var ownTracks: [AudioCodecPolicy.OutputAudioTrack]? = nil
    /// The point this clip's kept range is trimmed to for a **truncated ending** (issue #79),
    /// or `nil` when it has none — the single truncated-ending classification
    /// (`ExportPlanner.truncatedEndingTrim`), decided once at plan time. The conform executor
    /// consumes it via `conform.trimEnd`; the smart-render engine reaches the same verdict
    /// through `BoundaryReencodeEngine.trimmedSlotBudget`; the completion report reads this so
    /// the "and a truncated ending" wording can never disagree with what the engine trimmed.
    var truncatedEndingTrim: Double? = nil
}

enum ExportError: LocalizedError {
    case noClips
    case invalidPlan
    case cutFailed(String)
    case conformFailed(String)
    case concatFailed(String)
    case missingSegment
    case verificationFailed(String)
    /// A planned output path equals one of the export's own source files (issue #77):
    /// the clip's video source or an external audio source. Writing there would truncate
    /// the source before it is read (ffmpeg `-y`, `placeFile`'s remove-then-move) and
    /// destroy the original — so the export refuses before touching disk.
    case destinationIsSource(clip: String, path: String)
    /// The user cancelled (issue #32) — not a failure. Carries how many `.separate`
    /// files had already finished (and stay on disk) so the status line can say so.
    case cancelled(finished: Int, total: Int)
    /// A clip isn't ready to export (issue #78): still probing/indexing, failed to
    /// import, or source-missing. The button gates on this, but the keyboard/automation
    /// path can reach `export()` regardless — so it refuses with the ready-made,
    /// user-readable reason rather than routing an unprobed clip (`video == nil`) into
    /// smart render, where the encoder would silently default to libx264 (ADR-0009).
    case clipNotReady(String)
    /// A field-coded (PAFF) H.264 clip's plan contains a re-encode segment (issue #96).
    /// The cut editor pre-snaps every mark on such a clip to a copy-valid boundary
    /// (`CopyCutSnapper`), so its plan is copy-only *by construction* — a re-encode
    /// segment here can only be a programming error (stale points marked before the
    /// clip was known field-coded, a snapper bug, or a path that bypassed snapping),
    /// never a fallback to take: re-encoding PAFF is structurally broken, the
    /// field-counting frame index and the whole-frame encoder disagree by 2×
    /// (ADR-0022). The planner refuses loudly instead of silently producing it.
    case fieldCodedPlanNotCopyOnly(clip: String)
    /// A clip has no source for an output audio track *and* no usable kept duration —
    /// unknown or zero (issue #111) — so its silence leg has no length to be generated to.
    /// Written as zero samples it would contribute nothing and drag every later clip
    /// earlier, so the export refuses instead. The planner always stamps a positive kept
    /// duration, so this is an invariant guard.
    case unknownSilenceLength(clip: String, track: Int)

    var errorDescription: String? {
        switch self {
        case .noClips: return "There are no clips to export."
        case .invalidPlan: return "A clip's in/out points collapse to nothing after snapping to clean cut points."
        case .cutFailed(let d): return "Could not cut a clip.\n\(d)"
        case .conformFailed(let d): return "Could not conform a clip to the target.\n\(d)"
        case .concatFailed(let d): return "Could not join the clips.\n\(d)"
        case .missingSegment: return "The expected output segment was not produced."
        case .verificationFailed(let d): return "The cut did not verify and was not saved.\n\(d)"
        case .destinationIsSource(let clip, let path):
            return "The export would overwrite the source of “\(clip)” at \(path); the original would be destroyed. Choose a different destination."
        case .cancelled: return "The export was cancelled."
        case .clipNotReady(let reason): return reason
        case .fieldCodedPlanNotCopyOnly(let clip):
            return "Internal error: the cut points of “\(clip)” don’t sit on clean copy boundaries, but the clip is field-coded and can only be cut by pure stream copy. Re-mark the in and out points in the cut editor and export again."
        case .unknownSilenceLength(let clip, let track):
            return "Internal error: “\(clip)” has no audio for track \(track) and no known length, so the silence standing in for it can’t be measured. Re-mark the in and out points of that clip and export again."
        }
    }
}

/// Milestone 1 export: cut each clip at its clean cut points with a pure video
/// stream-copy (the ffmpeg segment muxer), then connect or separate the pieces
/// (ADR-0008). No video re-encode — frame-exact or it does not cut there.
///
/// Audio is **re-encoded** rather than copied: a stream-copied audio cut lands on an
/// audio-packet boundary, not the video cut, leaving the two ~tens of ms apart at every
/// join (measured ~120 ms on real footage). Instead each clip's audio is decoded over
/// its exact kept range and concatenated at the sample level into one continuous track
/// (a single encode — no per-join priming gaps), then muxed against the copied video.
///
/// The argument builders are pure so the exact command shape can be unit-tested; the
/// recipes themselves were validated against real H.264/HEVC/MPEG-2 footage in the shell.
enum ExportEngine {
    private static let audioBitrate = "192k"

    /// What feeds one audio leg (ADR-0014).
    enum AudioSource: Equatable {
        /// The clip's own file's Nth audio stream (0-based).
        case stream(Int)
        /// The Nth audio stream of an external file (audio-only or another video),
        /// aligned file start = video-file start, so the clip's kept window cuts the
        /// same span out of it.
        case external(URL, stream: Int)
    }

    /// Output bitstream filter that makes matroska accept stream-copied MPEG-2 (issue #2).
    /// Real MPEG-PS broadcast captures carry occasional video packets with **no PTS at
    /// all** (the second frame of each duplicated-timestamp anomaly — the broadcast fixture has
    /// them; even a plain whole-file remux failed with "Can't write packet with unknown
    /// timestamp"). TS and MP4 tolerate a missing PTS; matroska refuses the packet. The
    /// `setts` filter refills exactly those packets' PTS from their DTS — the same refill
    /// `FrameIndexer.parseIndex` applies when numbering frames (ADR-0006), so the muxed
    /// timestamps agree with the app's frame index and the verify gate's source pattern.
    /// All other packets pass through untouched, so on a fully-stamped source it is the
    /// identity. Scoped to mpeg2video→MKV — plus any **damaged** clip→MKV (issue #47):
    /// a damaged source carries no-PTS packets whatever its codec (the 1844 capture's
    /// truncated pictures), and they kill the MKV copy cut even when the kept window is
    /// clean, because the segment muxer writes the *discarded* segments too. Validated
    /// on the real capture in the shell (refill → exit 0; without → "Can't write packet
    /// with unknown timestamp"). Every clean clip's command stays byte-identical.
    static func ptsRefillBitstreamFilter(codec: String?, ext: String, damaged: Bool = false) -> [String] {
        guard codec == "mpeg2video" || damaged, ext.lowercased() == "mkv" else { return [] }
        return ["-bsf:v", "setts=pts=if(eq(PTS\\,NOPTS)\\,DTS\\,PTS)"]
    }

    /// Whether the plan trims either end. When neither end is cut the clip is copied
    /// whole with a plain remux — the segment muxer would otherwise split it at *every*
    /// keyframe (it only honours explicit cut points).
    static func needsCut(_ plan: SegmentPlan) -> Bool {
        plan.inSegmentTime != nil || plan.outSegmentTime != nil
    }

    /// Whether a plan is the whole-clip single-copy keep: one copy segment cutting
    /// neither end (starts at frame 0, no out-cut keyframe). This is the shape whose
    /// `BoundaryReencodeEngine.copySegmentPlan` carries no segment time at either end —
    /// the nil-cut plan `needsCut` rejects — so the clip goes through the plain remux
    /// (`remuxArguments`), never the segment muxer. The single owner of that remux
    /// criterion; `pieceExtension` keys its whole-clip exception off it.
    static func isWholeClipCopy(_ plan: [PlannedSegment]) -> Bool {
        plan.count == 1 && plan[0].kind == .copy
            && plan[0].range.lowerBound == 0 && plan[0].outCutKeyframe == nil
    }

    /// The container one clip's intermediate video **pieces** are produced in — the
    /// per-item rule, i.e. the clip alone in its own join (a `.separate` item, or a
    /// single-clip `.connect`; a multi-clip join layers `pieceExtensions` on top):
    /// normally the output container itself, so pieces feed the concat/final mux without
    /// a rewrap. A **field-coded (PAFF) clip that is actually cut** is the exception
    /// (issue #96): its pieces are always `.ts`, whatever the output container.
    /// Matroska stores no independent DTS, so an MKV piece of a field-coded cut
    /// collapses the B-field PTS dips into duplicate timestamps when the concat demuxer
    /// regenerates DTS from PTS; TS pieces carry the real DTS, and TS pieces feeding
    /// TS, MKV *and* MP4 final outputs were all validated clean on the real capture in
    /// the shell. The `.ts` piece also sidesteps the MP4 `-segment_format_options
    /// video_track_timescale` pin (#18/#24) by construction — every timescale flag
    /// downstream is gated on the *piece* extension, and a TS piece imposes the
    /// container's fixed 1/90000 timebase.
    ///
    /// A field-coded clip **kept whole** (`isWholeClipCopy`) stays on today's
    /// plain-remux path in the output container, byte-for-byte unchanged: no cut means
    /// no piece boundary for MKV's DTS regeneration to collapse.
    static func pieceExtension(container: String, fieldCoded: Bool, plan: [PlannedSegment]) -> String {
        guard fieldCoded else { return container }
        return isWholeClipCopy(plan) ? container : "ts"
    }

    /// The piece container for **every** item of one export, aligned by index. `.separate`
    /// items are each their own single-clip join, so the per-item `pieceExtension` rule
    /// applies unchanged — as it does to a single-clip `.connect`. A multi-clip `.connect`
    /// join containing any field-coded item instead produces **every** video piece in the
    /// join as `.ts` — other clips' cut pieces, whole-clip remuxes, and conform re-encodes
    /// included — because the concat demuxer misplaces a mixed-container list outright
    /// (issue #96 shell de-risk on the real capture): an MKV piece next to a `.ts` piece
    /// put the following clip ~90× late (the MKV piece's duration re-read in the TS
    /// piece's 1/90000 timebase — a 39.9 s piece pushed its neighbour to ~3593 s), and the
    /// reversed order collapsed the MKV piece's 998 frames onto duplicate PTS. All-`.ts`
    /// lists fed TS, MKV and MP4 finals cleanly — exact packet sums, single-field seam
    /// steps, strictly monotonic DTS where the container carries DTS — in both clip
    /// orders, for cut pieces and whole-keep remux pieces alike.
    static func pieceExtensions(container: String, mode: OutputMode, items: [ExportItem]) -> [String] {
        if mode == .connect, items.count > 1, items.contains(where: \.fieldCoded) {
            return Array(repeating: "ts", count: items.count)
        }
        return items.map {
            pieceExtension(container: container, fieldCoded: $0.fieldCoded, plan: $0.segments)
        }
    }

    // MARK: - Reorder depth (ADR-0026, issue #106)

    /// The **reorder depth** every piece of one output must agree on: the deepest depth any
    /// *copy* piece in it will carry. Matroska stores no DTS, so the demuxer latches a
    /// joined file's reorder depth from its first piece; a later piece needing a deeper one
    /// is read with non-monotonic DTS, which the next stream-copy mux turns into duplicate
    /// PTS and early frames (`EncoderSelection.reorderDepthParams`). Copy pieces carry the
    /// source's depth and can't be changed — so they set the bar, and the pieces this app
    /// *encodes* are matched to it.
    ///
    /// A conformed item contributes nothing: its every piece is a fresh encode. A
    /// smart-rendered item contributes its source's depth only when the plan actually
    /// copies something. An unprobed depth counts as the shallow 1, the floor the shallowest
    /// join needs anyway.
    static func joinReorderDepth(items: [ExportItem]) -> Int {
        items.reduce(1) { deepest, item in
            guard item.conform == nil, item.segments.contains(where: { $0.kind == .copy }) else {
                return deepest
            }
            return max(deepest, item.sourceReorderDepth ?? 1)
        }
    }

    /// The reorder depth **one item's** re-encoded pieces are produced at. The join's depth
    /// (`joinReorderDepth`) when this item's own first piece is one this app encodes — then
    /// that piece is what the join latches, so it must declare the deepest depth in the
    /// join. Otherwise the item's first piece is a stream copy carrying its *source's*
    /// depth, and its own later re-encodes must not out-deepen it: matching the source is
    /// the most this item can do (and keeps its own internal join readable). Whether the
    /// join as a whole then stays readable is what `ExportPlanner.reorderDepthWarning`
    /// judges — this is a per-item recipe, not a promise about the file.
    ///
    /// Never deeper than the encoders can reach (`deepestEncodableReorderDepth`), so the
    /// value handed to the encoders is always one they can actually produce.
    static func pieceReorderDepth(item: ExportItem, joinDepth: Int) -> Int {
        let depth = firstPieceIsEncoded(item) ? joinDepth : (item.sourceReorderDepth ?? 1)
        return min(depth, EncoderSelection.deepestEncodableReorderDepth)
    }

    /// Whether the item's first video piece is one this app encodes (a conform, or a plan
    /// whose first segment is a re-encode) rather than a stream copy — i.e. whether the
    /// depth its container declares is ours to choose.
    static func firstPieceIsEncoded(_ item: ExportItem) -> Bool {
        if item.conform != nil { return true }
        return item.segments.first?.kind == .reEncode
    }

    /// The segment the wanted piece lands in: index 0 when the clip starts at its own
    /// beginning (no head cut), otherwise index 1 — the piece after the in-cut.
    static func wantedSegmentIndex(plan: SegmentPlan) -> Int {
        plan.inSegmentTime == nil ? 0 : 1
    }

    /// How far past a copy's last wanted moment the read is allowed to run (issue #107).
    /// The bound has to clear the wanted piece by **more than one frame interval**: the
    /// muxer's split is placed by DTS, so a read stopping level with the cut time drops
    /// the last frame or two — silently, exit 0, no stderr. Measured on the HEVC fixture:
    /// 0 → 2 frames short, 0.02 → 1 short, 0.05 → exact but knife-edge. ~2 s is well clear
    /// at any rate and still ~65% less temp than reading to EOF.
    static let copyReadMargin = 2.0

    // MARK: - Head seek (issue #108)

    /// Where a copy's read is allowed to *start*, once measured (issue #108). Bounding the
    /// read's end (#107) left the pre-in-cut **head**: the segment muxer still opened at
    /// frame 0 and wrote everything before the wanted piece as a discarded segment, so the
    /// throwaway grew with the clip's in-point — 8.6 GB for one 54 s copy 150 min into a
    /// 4h36 capture, ~100 GB across a nine-clip MotoGP render.
    ///
    /// The muxer places `-segment_times` relative to **the first packet it sees**, not to
    /// the file start (measured: the split moves keyframe-for-keyframe with the seek
    /// landing). So an input seek is only safe if the landing is *known*, and it cannot be
    /// predicted from the index: on the real open-GOP HEVC capture `-ss` at a keyframe's own
    /// pts landed a whole keyframe earlier than asked, because the Matroska cues don't index
    /// every keyframe the packet flags call one. It is measured instead —
    /// `BoundaryReencodeEngine.copyHeadSeek` runs a one-packet probe down the same seek code
    /// path — and the split times are then re-expressed against it.
    struct CopyHeadSeek: Equatable {
        /// The `-ss` value: start_time-relative, like every other input seek in the engine.
        var seek: Double
        /// Where ffmpeg actually landed, on the index's own axis (`pts − index.pts.first`) —
        /// the axis `FrameIndex.segmentTime(forCutAt:)` speaks. Subtracting it from a segment
        /// time converts "seconds from the file start" into "seconds from this run's first
        /// packet", which is what the muxer compares against. Whatever constant offset ffmpeg
        /// then applies to the output timeline cancels: both the split and the origin move
        /// with it.
        var origin: Double
    }

    /// The keyframe a copy segment's read may start from — far enough before the in-cut that
    /// the muxer still has a non-empty segment `000` to put the head in (`wantedSegmentIndex`
    /// stays 1), and no further. Two keyframes back rather than one, so a landing that
    /// undershoots by a keyframe (which the real HEVC capture does) still leaves a head
    /// segment; a single keyframe back is taken when that's all there is.
    ///
    /// `nil` when there is nothing to skip — no in-cut, or no keyframe before it — and the
    /// copy keeps today's read-from-zero recipe.
    static func copyHeadSeekTarget(plan: SegmentPlan, index: FrameIndex,
                                   containerStart: Double) -> Double? {
        guard plan.inSegmentTime != nil,
              let previous = index.keyframeIndex(atOrBefore: plan.inFrame - 1) else { return nil }
        let anchor = index.keyframeIndex(atOrBefore: previous - 1) ?? previous
        return max(0, index.pts[anchor] - containerStart)
    }

    /// ffmpeg args to cut one clip's **video** into segments at its clean cut points.
    /// Cuts are placed by **decode** time (ADR-0008): the muxer splits at the first
    /// keyframe whose DTS reaches the segment time. With explicit `-segment_times` the
    /// muxer splits *only* there, so internal keyframes are carried through untouched.
    /// Assumes `needsCut(plan)`.
    ///
    /// An out-cut also bounds the **read** (`-t`, issue #107). Unbounded, the segment
    /// muxer reads to EOF and writes every segment past the wanted one — the whole source
    /// tail, as temp files, discarded (43 GB of trailing segments on a 4h36 capture). The
    /// bound is evaluated on the *unreset* output timeline, so `-reset_timestamps 1`
    /// doesn't interfere, and it is start-relative exactly like the segment times
    /// (ADR-0008) — hence `-t` and not `-to`. Without an out-cut the wanted piece runs to
    /// the file end, so the read must still reach EOF.
    ///
    /// A `headSeek` also bounds where the read *starts* (`-ss`, issue #108), which is what
    /// keeps the discarded pre-in-cut head to a couple of GOPs instead of the whole source
    /// before the clip. Every time then moves onto the seek's own timeline: the muxer
    /// measures `-segment_times` from its first packet, so the split times are offset by the
    /// measured landing (`CopyHeadSeek.origin`), and `-t` — a *duration*, not an instant —
    /// shortens by the same amount. The seek is deliberately not used to place the in-cut:
    /// the cut stays the DTS-midpoint split it has always been (ADR-0008), which is why the
    /// wanted piece comes out packet-identical to the unseeked read on MPEG-2, H.264 and
    /// open-GOP HEVC into `.mkv`, `.mp4` and `.ts`.
    static func cutArguments(source: URL, plan: SegmentPlan, segmentPattern: String,
                             bitstreamFilter: [String] = [], trackTimescale: Int? = nil,
                             headSeek: CopyHeadSeek? = nil) -> [String] {
        var args = ["-v", "error"]
        if let headSeek { args += ["-ss", Self.timeString(headSeek.seek)] }
        args += ["-i", source.path, "-map", "0:v:0", "-c", "copy"]
        args += bitstreamFilter
        args += ["-f", "segment"]
        // The segment muxer doesn't forward bare muxer flags to the inner mp4 muxer —
        // the export-wide timescale pin (issue #24) rides -segment_format_options.
        if let trackTimescale {
            args += ["-segment_format_options", "video_track_timescale=\(trackTimescale)"]
        }
        let origin = headSeek?.origin ?? 0
        let times = [plan.inSegmentTime, plan.outSegmentTime].compactMap { $0 }
        args += ["-segment_times", times.map { Self.timeString($0 - origin) }.joined(separator: ",")]
        args += ["-reset_timestamps", "1"]
        if let out = plan.outSegmentTime {
            args += ["-t", Self.timeString(out + Self.copyReadMargin - origin)]
        }
        args.append(segmentPattern)
        return args
    }

    /// ffmpeg args to copy a whole clip's **video** to a single file (no cut). Used when
    /// the plan trims neither end.
    static func remuxArguments(source: URL, output: URL, bitstreamFilter: [String] = [],
                               trackTimescale: Int? = nil) -> [String] {
        var args = ["-v", "error", "-i", source.path, "-map", "0:v:0", "-c", "copy"]
        args += bitstreamFilter
        if let trackTimescale { args += ["-video_track_timescale", String(trackTimescale)] }
        args.append(output.path)
        return args
    }

    /// The single video track timescale an MP4 export pins on **every** piece — copies,
    /// boundary re-encodes, and conform re-encodes (issue #24). Pieces from different
    /// muxer runs otherwise land in different timescales and the concat demuxer reads
    /// them all in the first piece's: a 1/90000 clip after a 1/25000 one plays stretched
    /// 3.6×, and a conform's encoder-default 1/12800 track collapses onto ~0 spacing.
    ///
    /// The least common multiple of the clips' **measured** timescales (the one-packet
    /// copy probe — never the source container's time_base, the MKV 1/1000 trap) is the
    /// smallest value that represents every clip's frame timing in whole ticks — the
    /// correctness bar; no clip's frame durations may round. `nil` (no probes, or an LCM
    /// past the 32-bit muxer range) means no export-wide pin — the per-clip #18 behavior
    /// then applies unchanged.
    static func exportWideTimescale(probed: [Int]) -> Int? {
        guard !probed.isEmpty else { return nil }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        var acc = 1
        for value in probed where value > 0 {
            let (multiplied, overflow) = acc.multipliedReportingOverflow(by: value / gcd(acc, value))
            guard !overflow, multiplied <= Int(Int32.max) else { return nil }
            acc = multiplied
        }
        return acc > 1 ? acc : nil
    }

    /// Bounds how many one-packet timescale probes overlap (issue #85). Each is a short
    /// stream-copy + ffprobe; a handful in flight overlaps the I/O without a process storm
    /// (the spirit of the import throttle).
    static let timescaleProbeConcurrency = 4

    /// Combines the per-clip timescale probe results into the export-wide MP4 pin —
    /// **all-or-nothing** (issue #85). A single unprobeable clip (`nil`) yields *no* pin:
    /// the pin is stamped on *every* piece (copies included, ADR-0009 #24), so a value that
    /// isn't a whole-tick multiple of the unprobed clip's own timescale would round its
    /// copied frame durations — a partial LCM would silently misrepresent that clip, which
    /// then falls back to its own per-#18 pin only if there is no export-wide pin at all.
    /// With every clip measured, the pin is their LCM (`exportWideTimescale(probed:)`).
    static func exportWideTimescale(probes: [Int?]) -> Int? {
        guard !probes.isEmpty else { return nil }
        var measured: [Int] = []
        for p in probes {
            guard let p else { return nil }   // any unprobeable clip → no export-wide pin
            measured.append(p)
        }
        return exportWideTimescale(probed: measured)
    }

    /// One clip's measured MP4 track timescale (issue #18/#24): stream-copy a single video
    /// packet into a throwaway MP4 and read back the muxer-assigned track timescale — never
    /// derived from the source time_base (the MKV 1/1000 auto-raise trap). `nil` when the
    /// probe (either process) fails.
    private static func probeTrackTimescale(ffmpeg: URL, source: URL, output: URL) async -> Int? {
        guard let result = try? await ProcessRunner.run(
                  ffmpeg, BoundaryReencodeEngine.timescaleProbeArguments(source: source, output: output)),
              result.status == 0 else { return nil }
        return BoundaryReencodeEngine.trackTimescale(timeBase: await MediaProbe.videoTimeBase(url: output))
    }

    /// Measures every clip's MP4 track timescale concurrently (bounded by
    /// `timescaleProbeConcurrency`), returning results in `sources` order (the LCM combine is
    /// order-independent, but keeping order keeps the mapping legible). The probes are
    /// independent short-lived subprocesses writing distinct `tsprobe_N.mp4` files, so
    /// overlapping them turns the old serial per-clip stall into one bounded fan-out
    /// (issue #85). A single failure still nils the whole pin — that decision lives in
    /// `exportWideTimescale(probes:)`, not here.
    private static func probeTrackTimescales(ffmpeg: URL, sources: [URL], work: URL) async -> [Int?] {
        var results = [Int?](repeating: nil, count: sources.count)
        await withTaskGroup(of: (Int, Int?).self) { group in
            var next = 0
            let seed = min(timescaleProbeConcurrency, sources.count)
            while next < seed {
                let i = next
                let source = sources[i]
                let output = work.appendingPathComponent("tsprobe_\(i).mp4")
                group.addTask { (i, await probeTrackTimescale(ffmpeg: ffmpeg, source: source, output: output)) }
                next += 1
            }
            while let (i, ts) = await group.next() {
                results[i] = ts
                if next < sources.count {
                    let j = next
                    let source = sources[j]
                    let output = work.appendingPathComponent("tsprobe_\(j).mp4")
                    group.addTask { (j, await probeTrackTimescale(ffmpeg: ffmpeg, source: source, output: output)) }
                    next += 1
                }
            }
        }
        return results
    }

    /// ffmpeg args to join already-cut, same-codec video pieces with the concat demuxer —
    /// a pure stream-copy, so the join is frame-exact.
    static func concatArguments(listFile: URL, output: URL) -> [String] {
        ["-v", "error", "-f", "concat", "-safe", "0", "-i", listFile.path, "-c", "copy", output.path]
    }

    /// The concat demuxer's list file: one `file '<path>'` line per piece. Single quotes
    /// in a path are escaped (`'\''`) so a filename can't break out of the directive.
    ///
    /// `durations` (one optional entry per piece, aligned by index) adds a `duration
    /// <seconds>` directive after a piece's `file` line. That pins how far the demuxer
    /// advances the timeline before the *next* piece, overriding the container-reported
    /// duration. It matters because a stream-copied head piece that kept the source's
    /// non-zero `start_time` reports a duration inflated by that leading offset (the MKV/MP4
    /// duration field measures from zero, so it includes the gap before the first frame);
    /// the demuxer would then place the following piece one slot late and open a gap at the
    /// seam (the start_time off-by-one, ADR-0008). The true span — `pts[upperBound] -
    /// pts[lowerBound]` of the piece's kept frames — closes it. Container-agnostic: on a TS
    /// piece, whose offset the mpegts muxer already normalises uniformly, the directive
    /// equals the real span and changes nothing (verified on H.264/MPEG-2/HEVC in the shell).
    /// An omitted/`nil` entry emits no directive — the default (`[]`) reproduces the bare list.
    static func concatListContents(pieces: [URL], durations: [Double?] = []) -> String {
        var lines: [String] = []
        for (i, piece) in pieces.enumerated() {
            lines.append("file '\(piece.path.replacingOccurrences(of: "'", with: "'\\''"))'")
            if i < durations.count, let d = durations[i], d > 0 {
                lines.append("duration \(timeString(d))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The timeline span (seconds) each clip's video piece should occupy in the **cross-clip**
    /// concat — the `duration` directives fed to `concatListContents`, closing the same
    /// start_time seam gap `BoundaryReencodeEngine.segmentSpans` closes inside a clip
    /// (issue #6). The biting piece is a single-copy-segment clip trimmed only at its tail
    /// (segment 0 of the muxer cut keeps the source's non-zero start_time; an MKV piece's
    /// container duration then includes that leading offset and the next clip lands late).
    /// De-risked in the shell on H.264/HEVC/MPEG-2: the cross-clip gap shows in MKV only
    /// (unlike the within-clip case, the MP4 piece's duration matched its true span —
    /// noted in ADR-0008), and the directive closes it; on MP4/TS pieces — and every
    /// internally-normalized piece — the directive equals the real span and is a no-op.
    ///
    /// A smart-rendered clip's span comes from its plan: the segments tile the kept range
    /// `[lo, hi)` contiguously, so the span is `pts[hi] - pts[lo]` — exact when the clip is
    /// trimmed (`hi` is a real frame). When it runs to the clip end (`hi == count`,
    /// `pts[hi]` out of bounds) the last frame's slot is estimated from the mean frame
    /// interval — safe because no piece ships with non-uniform spacing anyway (the
    /// `timestampDefect` self-check in `verifyPiece`). A conformed clip re-encodes its kept window
    /// to the target spec preserving duration, so its span is the kept duration the app
    /// supplies. The last clip offsets nothing → `nil`; an uncomputable span degrades to
    /// `nil` (no directive — today's behavior) rather than guessing.
    static func clipSpans(items: [ExportItem]) -> [Double?] {
        items.enumerated().map { i, item in
            i < items.count - 1 ? clipSpan(item) : nil
        }
    }

    /// The `duration` directives the **cross-clip** concat list actually carries:
    /// `clipSpans`, **per entry**, with a field-coded item's entry nil'd (issue #96).
    /// Dropping the whole list for one field-coded item would reopen the issue-#6 /
    /// ADR-0008 seam gap for every *other* clip in the join — the directive exists
    /// precisely because a container-native piece can report a start_time-inflated
    /// duration — so non-field-coded entries keep theirs unconditionally. In a
    /// field-coded join every piece is `.ts` anyway (`pieceExtensions`), where the
    /// progressive entry's directive is a byte-identical no-op (measured in the shell:
    /// list with and without it produced identical MKV finals) because a cut `.ts`
    /// piece self-reports exactly its true content span.
    ///
    /// A field-coded entry emits none. Its *cut* piece's directive would equally be a
    /// no-op (the field index's `pts[hi] − pts[lo]` matches the mpegts-reported
    /// duration exactly — 60.52 s over 3026 fields on the real capture), but its
    /// *whole-keep remux* piece's span is the mean-interval estimate, which
    /// under-states a ragged-tail broadcast capture's true content span; the too-short
    /// directive then overlapped the next clip into the tail (a duplicate video PTS in
    /// the MKV final, measured on the real capture), while the directive-free entry
    /// seamed at exactly one frame step. The mpegts-reported duration is the accurate
    /// value for every `.ts` piece, so the demuxer's own placement is the proven form.
    static func crossClipDurations(items: [ExportItem]) -> [Double?] {
        zip(clipSpans(items: items), items).map { span, item in
            item.fieldCoded ? nil : span
        }
    }

    /// One clip's kept video span in seconds (see `clipSpans`).
    static func clipSpan(_ item: ExportItem) -> Double? {
        if item.conform != nil { return keptDuration(item) }
        guard let first = item.segments.first, let last = item.segments.last else { return nil }
        let pts = item.index.pts
        let lo = first.range.lowerBound, hi = last.range.upperBound
        guard lo < pts.count, hi <= pts.count else { return nil }
        if hi < pts.count { return pts[hi] - pts[lo] }
        guard pts.count >= 2 else { return nil }
        let interval = (pts[pts.count - 1] - pts[0]) / Double(pts.count - 1)
        return pts[pts.count - 1] - pts[lo] + interval
    }

    /// Inspects a produced piece's presentation timestamps (sorted ascending) for the two
    /// timestamp defects this engine has shipped: a **duplicate** PTS (two frames sharing a
    /// timestamp — the B-pyramid/MKV stream-copy collapse, ADR-0011) and a **seam gap** (a
    /// frame slot skipped — the start_time concat offset, ADR-0008). Within one produced
    /// piece the frame rate is constant, so a clean piece is near-uniformly spaced: an
    /// interval at or below half the median is a duplicate, at or above 1.5× is a gap. The
    /// generous band tolerates float jitter while still catching a whole missing/collapsed
    /// frame. Returns a human-readable reason, or `nil` when clean (or too short to judge).
    /// Pure, so it is unit-tested against captured-defect timestamps; the export engines run
    /// it as a final self-check before a piece ships, so neither defect can slip out silently.
    static func timestampDefect(pts: [Double]) -> String? {
        timestampDefect(pts: pts, plan: [], sourcePts: [])
    }

    /// Plan-aware variant (issue #19): a stream-copied span is a *faithful* copy, so its
    /// timestamps legitimately reproduce the source's own irregularities (the 2009
    /// broadcast capture has ~714 duplicate+gap anomalies in 67 min — rejecting them
    /// rejected correct exports). Inside a **copy** segment an anomaly is a defect only
    /// when the source has no same-kind anomaly within ±3 intervals of the corresponding
    /// position: the mpegts round-trip surfaces the second frame of a source duplicate
    /// with no pts, the indexer refills it from dts (ADR-0006), and that displaces the
    /// re-materialized anomaly by up to the B-frame reorder depth — measured 2 on the
    /// real fixture, so ±3 covers the ≤3-B-frame GOPs of this domain. **Re-encoded**
    /// segments, the seam intervals between segments, and a 2-interval window at every
    /// segment edge keep strict uniformity — that is where the shipped defect classes
    /// (start_time seam gap, B-pyramid/MKV collapse, timescale squeeze) live, and the
    /// de-risk caught a real misplaced-seam defect exactly there. An anomaly the source
    /// has that the output lacks is never a defect (containers may normalize).
    ///
    /// With no plan (or a frame-count mismatch, which gate 1 reports separately) every
    /// interval is held to strict uniformity — the pre-#19 behavior, still what a full
    /// re-encode (`ConformEngine`) wants.
    ///
    /// `outputCounts` (one entry per plan segment) re-anchors the mapping when a
    /// segment's produced frame count differs from its source range — a repaired
    /// re-encode fills holes and drops corrupt frames (issue #47), shifting where every
    /// later copy span lands in the piece. Omitted, each segment is its range's length.
    static func timestampDefect(pts: [Double], plan: [PlannedSegment], sourcePts: [Double],
                                outputCounts: [Int]? = nil) -> String? {
        guard pts.count >= 3 else { return nil }
        let deltas = zip(pts.dropFirst(), pts).map { $0 - $1 }
        let median = deltas.sorted()[deltas.count / 2]
        guard median > 0 else { return "frames share a timestamp (zero median interval)" }

        // Output index of each segment's first frame; the plan tiles the piece, so
        // output frame `starts[s] + k` is source frame `plan[s].range.lowerBound + k`
        // (copy segments always produce exactly their range).
        let counts = outputCounts ?? plan.map { $0.range.count }
        var starts: [Int] = []
        var total = 0
        for count in counts { starts.append(total); total += count }
        let planApplies = !plan.isEmpty && counts.count == plan.count && total == pts.count
            && !sourcePts.isEmpty
        func segmentIndex(of frame: Int) -> Int {
            var s = plan.count - 1
            while s > 0 && starts[s] > frame { s -= 1 }
            return s
        }
        let seamWindow = 2
        let matchRadius = 3
        func anomalyKind(_ d: Double) -> Int { d <= median * 0.5 ? -1 : (d >= median * 1.5 ? 1 : 0) }
        let sourceDeltas = zip(sourcePts.dropFirst(), sourcePts).map { $0 - $1 }

        for (i, d) in deltas.enumerated() {
            let kind = anomalyKind(d)
            if kind == 0 { continue }
            if planApplies {
                let s = segmentIndex(of: i)
                if plan[s].kind == .copy && segmentIndex(of: i + 1) == s {
                    let within = i - starts[s]
                    let lastInterval = counts[s] - 2
                    // The piece's outermost edges are not seams — nothing abuts the
                    // first segment's head or the last segment's tail, so a faithful
                    // copy may reproduce the source's anomaly right up to them (the
                    // HEVC fixture's B-pyramid tail cut presents a missing slot in
                    // its final interval). Interior edges keep the strict window.
                    let headGuard = s == 0 ? 0 : seamWindow
                    let tailGuard = s == plan.count - 1 ? 0 : seamWindow
                    if within >= headGuard && lastInterval - within >= tailGuard {
                        let m = plan[s].range.lowerBound + within
                        let nearby = (m - matchRadius)...(m + matchRadius)
                        if nearby.contains(where: { $0 >= 0 && $0 < sourceDeltas.count
                            && anomalyKind(sourceDeltas[$0]) == kind }) {
                            continue   // faithful reproduction of the source's anomaly
                        }
                    }
                }
            }
            if kind == -1 {
                return String(format: "frames at %.3fs and %.3fs are only %.4fs apart (~%.4fs expected — a duplicate)",
                              pts[i], pts[i + 1], d, median)
            }
            return String(format: "a %.4fs gap between %.3fs and %.3fs (~%.4fs expected — a frame slot was skipped)",
                          d, pts[i], pts[i + 1], median)
        }
        return nil
    }

    /// A clip's kept range as ffmpeg sees it: `start`/`end` are input-seek seconds —
    /// measured from the **container's start_time**, not absolute pts (ADR-0015) —
    /// and `duration` is the kept video span used to force every audio leg's length.
    struct KeptWindow: Equatable {
        var start: Double?
        var end: Double?
        var duration: Double
    }

    /// Converts a clip's kept range from frame-index pts (absolute presentation time)
    /// to the seek window the ffmpeg invocations need. ffmpeg's input `-ss` counts from
    /// the container's start_time, so passing absolute pts lands `containerStart`
    /// seconds late in content on a non-zero-start file (measured +230 ms audio-ahead
    /// on the MPEG-PS test clip — issue #3); the seek values subtract it. The duration
    /// stays in absolute pts.
    ///
    /// The kept **video** piece spans through the out frame's *display end*, not its pts:
    /// the smart-render plan keeps frames `[in, out+1)` and `clipSpan` measures
    /// `pts[out+1] - pts[in]`, so the last kept frame (`out`) still occupies its full
    /// slot. The window must end there too — at `outEndPts` (`pts[out+1]`), or one frame
    /// beyond the out pts at the file end where `pts[out+1]` doesn't exist. Ending at the
    /// out frame's own pts (the pre-#75 behavior) dropped that last slot, so every
    /// tail-trimmed audio leg was one frame shorter than its video and, forced to
    /// `duration` (ADR-0014), drifted a frame earlier per join in connect mode (#75). An
    /// open out end already ran to `lastPts + frameDuration` (last frame's display end)
    /// and is unchanged; a single-frame keep (`in == out`) now yields a one-frame
    /// duration instead of zero, so its leg is still length-forced.
    static func keptWindow(inPts: Double?, outPts: Double?, outEndPts: Double?,
                           firstPts: Double?, lastPts: Double?,
                           frameDuration: Double?, containerStart: Double) -> KeptWindow {
        let spanStart = inPts ?? firstPts ?? 0
        // A closed out point ends the window at the out frame's display end; open runs
        // one frame past the last frame's pts. Both leave `end` nil only when the out is
        // open (read audio to the file end).
        let closedEnd = outPts.map { outEndPts ?? ($0 + (frameDuration ?? 0)) }
        let spanEnd = closedEnd ?? ((lastPts ?? 0) + (frameDuration ?? 0))
        // Clamp the seek values ≥ 0, the same rule the seek builders apply
        // (`FrameStreamDecoder.seekSeconds` / `audioInputArgs`): a pts at/before the
        // container start (the very first frames) must not produce a negative `-ss`.
        // `duration` stays in absolute pts and is unaffected. `containerStart` is already
        // clamped ≥ 0 at parse (`MediaProbe.parseStartTime`), so on healthy inputs — where
        // the in/out pts sit at or after it — this is a no-op.
        return KeptWindow(start: inPts.map { max(0, $0 - containerStart) },
                          end: closedEnd.map { max(0, $0 - containerStart) },
                          duration: max(0, spanEnd - spanStart))
    }

    /// Input args selecting one clip's audio source range: a fast seek to `start` and a
    /// read duration. `-ss`/`-t` before `-i` are input options. An open start/end omits
    /// the corresponding flag (read from the file start / to the file end). `start`/`end`
    /// are input-seek seconds (`KeptWindow`), never absolute pts.
    ///
    /// `-max_error_rate 1.0` makes the run survive damaged sources (issue #44): at
    /// ffmpeg's default threshold (⅔) a window dominated by undecodable audio packets
    /// aborts with exit 69 and a silently *truncated* output — the real capture's 39 s
    /// MP2 dead zone did exactly that. At 1.0 the decode errors are tolerated and the
    /// gap-fill resample (`ConformEngine.audioFilter(fillGaps:)`) lays silence in their
    /// place. A clean source decodes with zero errors, so the flag changes nothing there
    /// (byte-identical legs in the issue #43 de-risk).
    static func audioInputArgs(source: URL, start: Double?, end: Double?) -> [String] {
        var a: [String] = ["-max_error_rate", "1.0"]
        if let start { a += ["-ss", timeString(start)] }
        if let end { a += ["-t", timeString(end - (start ?? 0))] }
        a += ["-i", source.path]
        return a
    }

    /// A clip's kept duration in seconds — the length every one of its audio legs is
    /// forced to. The app supplies it explicitly; the closed window is the fallback.
    private static func keptDuration(_ item: ExportItem) -> Double? {
        if let d = item.audioDuration, d > 0 { return d }
        guard let s = item.audioStart, let e = item.audioEnd, e > s else { return nil }
        return e - s
    }

    /// Final-mux args (ADR-0014): copy `videoInput`'s video (when present) and rebuild N
    /// continuous audio tracks — one sample-level concat chain per output track. Every
    /// leg is conformed to its track's rate/layout, backed by silence, and cut to the
    /// clip's exact kept duration in samples (ADR-0028 — tracks of one clip decode to
    /// slightly different lengths otherwise, and the output tracks would drift apart at
    /// every join). A clip with no source for a track contributes `anullsrc` silence in
    /// the track's format. `videoInput` is `nil` for an audio-only export.
    static func audioMuxArguments(videoInput: URL?, items: [ExportItem], tracks: [AudioCodecPolicy.OutputAudioTrack],
                                  audioCodec: String, output: URL) -> [String] {
        // -y: an existing file at the destination is overwritten silently — the
        // save panel's "Replace" already said yes, and `.separate` mode promises
        // re-exports land in place (issue #30).
        var args = ["-y", "-v", "error"]
        var nextInput = 0
        if let videoInput {
            args += ["-i", videoInput.path]
            nextInput = 1
        }
        // One input per clip, plus one per distinct external audio file a clip uses.
        // An external file gets the same seek window as the clip — it is aligned
        // file start = video-file start (ADR-0014), like a stream of the clip's own file.
        var ownInput: [Int] = []
        var externalInput: [[URL: Int]] = []
        for item in items {
            args += audioInputArgs(source: item.source, start: item.audioStart, end: item.audioEnd)
            ownInput.append(nextInput)
            nextInput += 1
            var externals: [URL: Int] = [:]
            for case .external(let url, _)? in item.audioSources where externals[url] == nil {
                args += audioInputArgs(source: url, start: item.audioStart, end: item.audioEnd)
                externals[url] = nextInput
                nextInput += 1
            }
            externalInput.append(externals)
        }

        var chains: [String] = []
        for (t, track) in tracks.enumerated() {
            var labels: [String] = []
            for (i, item) in items.enumerated() {
                // The leg's name; `[…]` wraps it wherever a chain references it, and the
                // leg's own intermediate labels suffix it (`c0t0src`, `c0t0pad`).
                let leg = "c\(i)t\(t)"
                let label = "[\(leg)]"
                // A clip with a kept duration contributes at least one sample: rounding a
                // sub-sample duration down to 0 would emit a zero-sample leg, which is the
                // very thing ADR-0028 exists to prevent.
                let samples = keptDuration(item).map { max(1, Int(($0 * Double(track.sampleRate)).rounded())) }
                let source = t < item.audioSources.count ? item.audioSources[t] : nil
                let mix = t < item.audioMixFilters.count ? item.audioMixFilters[t] : nil
                // Own stream and external file differ only in which input the leg reads.
                let input: String? = switch source {
                case .stream(let s): "[\(ownInput[i]):a:\(s)]"
                case .external(let url, let s): "[\(externalInput[i][url]!):a:\(s)]"
                case nil: nil
                }
                if let input {
                    chains += legChains(from: input, track: track, samples: samples,
                                        mix: mix, leg: leg)
                } else {
                    // A silence leg with no length can't be generated; the export refuses
                    // before this point (`assertAudioLegLengthsKnown`). One sample is the
                    // floor for the direct builder calls that don't go through it — a
                    // zero-sample leg is the defect of issue #111.
                    chains.append(silenceSource(track) + ",atrim=end_sample=\(samples ?? 1)" + label)
                }
                labels.append(label)
            }
            chains.append("\(labels.joined())concat=n=\(items.count):v=0:a=1[a\(t)]")
        }

        if !chains.isEmpty { args += ["-filter_complex", chains.joined(separator: ";")] }
        if videoInput != nil { args += ["-map", "0:v:0", "-c:v", "copy"] }
        for t in tracks.indices { args += ["-map", "[a\(t)]"] }
        if !tracks.isEmpty {
            if tracks.contains(where: { $0.encoder != nil }) {
                // Cut-only (ADR-0018): tracks of one output can encode to different
                // codecs, so each gets its own `-c:a:N` (de-risked in the shell on all
                // three formats in TS/MKV/MP4). A track without its own encoder takes
                // the export-wide codec.
                for (t, track) in tracks.enumerated() {
                    args += ["-c:a:\(t)", track.encoder ?? audioCodec]
                }
                args += ["-b:a", audioBitrate]
            } else {
                args += ["-c:a", audioCodec, "-b:a", audioBitrate]
            }
        }
        for (t, track) in tracks.enumerated() {
            if let language = track.language { args += ["-metadata:s:a:\(t)", "language=\(language)"] }
            if let title = track.title { args += ["-metadata:s:a:\(t)", "title=\(title)"] }
        }
        args.append(output.path)
        return args
    }

    /// One real audio leg, as the filter chains it needs (ADR-0028). The leg is conformed
    /// (`legFilter`), then **backed by an endless silence source and cut to the exact kept
    /// length**: `[real][silence]concat=n=2:v=0:a=1,atrim=end_sample=N`. The silence backing
    /// is what makes the length force survive a source that decodes to *nothing*.
    ///
    /// The pre-#111 force was `atrim=end_sample=N,apad=whole_len=N`. On a leg whose window
    /// decodes to zero frames that padding still wrote its samples but stopped advancing
    /// timestamps, so **every audio packet from that join onward carried one identical pts**
    /// — measured on a source whose audio ends before its video: 281 of 376 packets stamped
    /// 1.984 s, all 384 000 samples present, container duration 2.03 s of a planned 8 s,
    /// ffmpeg exit 0 and stderr empty. Concatenating silence *before* the trim gives the
    /// same graph a real stream to cut, so an empty leg becomes silence of exactly its
    /// clip's length: monotonic pts, correct extent, later clips un-shifted. Healthy legs
    /// are **bit-identical** to the old force (decoded-PCM md5, MPEG-2/H.264/HEVC, in .mkv,
    /// .mp4 and .ts) and the graph still terminates promptly at 68 legs (`anullsrc` is
    /// endless, but `atrim`'s EOF propagates: 0.42 s, same wall time and RSS as before).
    ///
    /// `samples == nil` — an unknown kept duration — leaves the leg **unforced**, exactly
    /// as before: with no length to cut to there is nothing to back it with either. Such a
    /// leg contributes its own natural length (nothing at all, if its window decodes to
    /// nothing), which shifts the clips after it but keeps the timeline monotonic. The
    /// planner always supplies a duration; only direct builder calls can reach this.
    private static func legChains(from input: String, track: AudioCodecPolicy.OutputAudioTrack,
                                  samples: Int?, mix: String?, leg: String) -> [String] {
        let conformed = input + legFilter(track: track, mix: mix)
        guard let n = samples else { return [conformed + "[\(leg)]"] }
        return [conformed + "[\(leg)src]",
                silenceSource(track) + "[\(leg)pad]",
                "[\(leg)src][\(leg)pad]concat=n=2:v=0:a=1,atrim=end_sample=\(n)[\(leg)]"]
    }

    /// One real audio leg's conform: the leg's channel mix when it has one (ADR-0019 —
    /// the mix shapes what *enters* the track, so it precedes the conform), then the
    /// conform to the track's rate/layout with the gap-fill resample (issue #44 — damaged
    /// spans become silence in place instead of closing up or aborting the run; a no-op on
    /// clean sources). The mix sits wholly before the length force, so the sample-exact
    /// cut the joins depend on is untouched (shell-verified: counts are identical with and
    /// without a mix on all three formats). Silence legs never come through here —
    /// generated silence has no gaps to fill.
    private static func legFilter(track: AudioCodecPolicy.OutputAudioTrack,
                                  mix: String? = nil) -> String {
        let conform = ConformEngine.audioFilter(sampleRate: track.sampleRate,
                                                channels: track.channels, fillGaps: true)
        return mix.map { $0 + "," + conform } ?? conform
    }

    /// Silence in one output track's format — the generator behind both a silence leg and
    /// every real leg's backing (ADR-0028). Endless by design: the `atrim` downstream is
    /// what sets the length, so no duration has to be computed twice.
    private static func silenceSource(_ track: AudioCodecPolicy.OutputAudioTrack) -> String {
        "anullsrc=r=\(track.sampleRate):cl=\(ConformEngine.channelLayout(track.channels))"
    }

    /// Refuses — before any file is written — if a clip would contribute a **silence** leg
    /// with no usable kept duration (issue #111): unknown, or zero, which `keptDuration`
    /// reports the same way. Silence has to be generated to a length, and the only lengths
    /// available are the clip's; with none, the leg could only be written as
    /// `end_sample=0`, which contributes nothing and pulls every later clip earlier. A
    /// *real* leg without a length is fine — it plays its own natural length
    /// (`legChains`) — so only the silence case refuses.
    ///
    /// The planner always stamps a kept duration (`ExportPlanner.planItem` → `keptWindow`,
    /// issue #75), so this is an invariant guard, not a user-facing condition; it reads the
    /// same track list the mux will use, per mode (`.separate` honours a clip's own tracks,
    /// ADR-0018).
    static func assertAudioLegLengthsKnown(items: [ExportItem],
                                           tracks: [AudioCodecPolicy.OutputAudioTrack],
                                           mode: OutputMode) throws {
        for item in items where keptDuration(item) == nil {
            let itemTracks = mode == .separate ? (item.ownTracks ?? tracks) : tracks
            for t in itemTracks.indices
            where t >= item.audioSources.count || item.audioSources[t] == nil {
                throw ExportError.unknownSilenceLength(clip: item.displayName, track: t + 1)
            }
        }
    }

    /// ffmpeg prints times locale-independently; format without scientific notation or
    /// a trailing locale decimal separator. Shared with the M2 boundary-re-encode engine.
    static func timeString(_ t: Double) -> String {
        var s = String(format: "%.6f", t)
        // trim trailing zeros / dot so 0.30 -> "0.3", matching the de-risk recipe.
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    // MARK: - Destination/source collision guard (issue #77)

    /// Every file this export will write, paired with the clip whose piece it holds. In
    /// `.connect` mode that is the single chosen `destination` (attributed to the first
    /// clip — the join has no single owner); in `.separate` mode it is each clip's
    /// generated `NN <name>.<ext>` path inside the chosen folder — the same names the
    /// `.separate` assembly writes, so the collision guard and the assembly can't disagree.
    /// `ext` is the export's video-container extension (audio-only outputs follow each
    /// clip's own codec, exactly as the assembly does).
    static func plannedOutputs(items: [ExportItem], settings: OutputSettings, ext: String,
                               audioCodec: String, to destination: URL) -> [(clip: String, url: URL)] {
        switch settings.mode {
        case .connect:
            return [(items.first?.displayName ?? "", destination)]
        case .separate:
            let exts = items.map { item in
                settings.type == .audioOnly
                    ? AudioCodecPolicy.audioFileExtension(forEncoder: item.ownTracks?.first?.encoder ?? audioCodec)
                    : ext
            }
            let names = separateFileNames(clipNames: items.map(\.displayName), exts: exts)
            return zip(items, names).map { (clip: $0.displayName, url: destination.appendingPathComponent($1)) }
        }
    }

    /// Refuses — before any file is written — if a file the export would write matches one
    /// of its own source files (issue #77): the clip's video source or an external audio
    /// source. ffmpeg writes with `-y` and `placeFile` removes-then-moves, so a destination
    /// equal to a source truncates the original before it is read and destroys the capture
    /// (the same collision `ClipDoctorEngine` already guards against). Comparison resolves
    /// symlinks and file identity (`denotesSameFile`). Throws `.destinationIsSource` naming
    /// the destroyed clip and the offending path.
    static func assertNoSourceCollision(items: [ExportItem], outputs: [(clip: String, url: URL)]) throws {
        var sources: [(clip: String, url: URL)] = []
        for item in items {
            sources.append((item.displayName, item.source))
            for case .external(let url, _)? in item.audioSources {
                sources.append((item.displayName, url))
            }
        }
        for output in outputs {
            for source in sources where denotesSameFile(output.url, source.url) {
                throw ExportError.destinationIsSource(clip: source.clip, path: output.url.path)
            }
        }
    }

    /// Whether two URLs denote the **same file** on disk — the guard that stops an export
    /// (or a Clip Doctor repair) from writing over one of its own sources (issue #77).
    /// Compares symlink-resolved, standardized paths (so a path and a symlink to it collide,
    /// and a not-yet-created destination resolves through its real parent directory), and —
    /// when both files already exist — also file identity (inode/device via
    /// `fileResourceIdentifierKey`), which catches hard links and aliases that pure path
    /// resolution misses.
    static func denotesSameFile(_ a: URL, _ b: URL) -> Bool {
        if resolvedOutputPath(a) == resolvedOutputPath(b) { return true }
        let fm = FileManager.default
        guard fm.fileExists(atPath: a.path), fm.fileExists(atPath: b.path),
              let ida = (try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier,
              let idb = (try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier
        else { return false }
        return (ida as? NSObject)?.isEqual(idb) ?? false
    }

    /// A URL's symlink-resolved, standardized filesystem path for collision comparison. The
    /// final component is resolved through its parent — which may itself be a symlink — so a
    /// not-yet-created destination still resolves to its real directory, while an existing
    /// file that is itself a symlink is resolved through to its target.
    static func resolvedOutputPath(_ url: URL) -> String {
        let std = url.standardizedFileURL
        let parent = std.deletingLastPathComponent().resolvingSymlinksInPath()
        return parent.appendingPathComponent(std.lastPathComponent)
            .resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - Orchestration

    /// Runs the full export: cut every clip's video, then connect or separate per
    /// `settings`, rebuilding the audio track when the output includes audio. In
    /// `.connect` mode `destination` is the file the user chose; in `.separate` mode it
    /// is the **folder** they chose, and each clip is written into it as
    /// `NN <clip name>.<ext>` in timeline order (issue #30), silently overwriting any
    /// existing file of the same name. `progress` reports 0…1, smoothed within each ffmpeg
    /// run from its `-progress` out_time (issue #9) and keeping the established 70 % video
    /// / 30 % audio phase split; it can be called from a background queue mid-run.
    static func export(
        items: [ExportItem],
        settings: OutputSettings,
        audioCodec: String = AudioCodecPolicy.fallbackAudioCodec,
        tracks: [AudioCodecPolicy.OutputAudioTrack] = [AudioCodecPolicy.OutputAudioTrack(sampleRate: 48000, channels: 2)],
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        guard !items.isEmpty else { throw ExportError.noClips }
        let wantsVideo = settings.type != .audioOnly
        if wantsVideo {
            // A clip is valid if it has an M2 smart-render plan or is being conformed (ADR-0011).
            guard items.allSatisfy({ !$0.segments.isEmpty || $0.conform != nil }) else {
                throw ExportError.invalidPlan
            }
        }
        // No mixed-codec refusal: a non-matching clip is conformed to the target's codec
        // (ADR-0011), so every piece reaching the concat is already the target codec.
        // No container refusal either — the one bad combination (mpeg2video into MKV)
        // is handled by the pts-refill bitstream filter (issue #2).

        let ffmpeg = try FFTools.ffmpegURL()
        // Video pieces use the container extension — except a field-coded clip's cut
        // pieces, and every piece of a multi-clip connect join that contains one, which
        // are all `.ts` whatever the container (`pieceExtensions`, issue #96); an
        // audio-only output has no video pieces and is written as an audio-elementary
        // file (ADR-0010 / #1). The *final* outputs — what `plannedOutputs` names and
        // the collision guard checks — are always the container extension: a `.ts`
        // piece is rewrapped on its way there, never placed under a container name it
        // isn't.
        let ext = AudioCodecPolicy.outputExtension(type: settings.type, container: settings.container, audioEncoder: audioCodec)
        // Refuse before touching disk if any planned output equals a source file (issue
        // #77): `-y` and `placeFile`'s remove-then-move would truncate the source before
        // reading it and destroy the original. Nothing is produced or written until this
        // passes, so a collision leaves every source intact.
        let outputs = plannedOutputs(items: items, settings: settings, ext: ext,
                                     audioCodec: audioCodec, to: destination)
        try assertNoSourceCollision(items: items, outputs: outputs)
        let wantsAudio = settings.type != .videoOnly
        // And refuse, equally early, a silence leg with no length to generate it to (issue
        // #111) — the one audio leg the rebuild cannot express without collapsing the
        // track's timeline.
        if wantsAudio {
            try assertAudioLegLengthsKnown(items: items, tracks: tracks, mode: settings.mode)
        }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        // Claim it for this process before a single piece is written (issue #109), so a hard
        // kill leaves a directory the next launch's sweep can recognise as a corpse — and so
        // a concurrent launch can tell this run is alive and leave it alone. The defer below
        // is unchanged: it still handles every exit a `defer` can reach.
        WorkDirectorySweeper.claim(work)
        defer { try? FileManager.default.removeItem(at: work) }

        // A cancel (issue #32) discards the file being written but keeps `.separate`
        // files that already finished — they are valid exports. Both are tracked here
        // so the catch below can act on them; the temp work dir is cleaned by the
        // defer like on any exit.
        var currentOutput: URL? = nil
        var finishedFiles = 0
        do {
        // 1. Produce each clip's video piece per its M2 plan — re-encode the head/tail
        //    edges, stream-copy the keyframe-bounded middle, concat (ADR-0009). The bulk
        //    of the work, and the only part that re-encodes.
        //    A non-matching clip is instead conformed: a full re-encode of its kept range to
        //    the target spec, self-verified before it ships (ADR-0011).
        var videoPieces: [URL] = []
        if wantsVideo {
            // One export-wide MP4 track timescale, measured per clip via the one-packet
            // copy probe and combined by LCM (issue #24) — stamped on every piece so
            // cross-clip joins can't stretch or collapse. Any unprobeable clip drops the
            // export-wide pin entirely (a partial pin would misrepresent the unprobed
            // clip's copies); the per-clip #18 behavior then applies as before.
            var exportTimescale: Int? = nil
            if ext.lowercased() == "mp4" {
                // Overlap the per-clip one-packet copy probes (bounded) instead of stalling
                // clip-by-clip; the all-or-nothing pin decision then lives in the pure combine
                // (issue #85). Any unprobeable clip drops the export-wide pin entirely (a
                // partial pin would misrepresent that clip's copies); the per-#18 behavior applies.
                let probes = await probeTrackTimescales(
                    ffmpeg: ffmpeg, sources: items.map(\.source), work: work)
                exportTimescale = exportWideTimescale(probes: probes)
            }
            // One piece container per item (issue #96): per-item `pieceExtension` for
            // `.separate` and single-clip joins; all-`.ts` for a multi-clip connect
            // join containing a field-coded item — a mixed-container concat list is
            // misplaced outright by the demuxer (see `pieceExtensions`). The engine's
            // internal MP4 timescale pins (#18/#24) key off the *piece* extension, so
            // they never reach a `.ts` piece.
            let pieceExts = pieceExtensions(container: ext, mode: settings.mode, items: items)
            // The reorder depth this output's pieces must agree on (ADR-0026): in
            // `.connect` the whole join sets it; in `.separate` each clip is its own file,
            // so each item sets its own.
            let joinDepth = settings.mode == .connect
                ? joinReorderDepth(items: items)
                : nil
            for (i, item) in items.enumerated() {
                let withinClip: @Sendable (Double) -> Void = { w in
                    progress(ExportProgress.clipFraction(clipIndex: i, clipCount: items.count, withinClip: w))
                }
                let depth = pieceReorderDepth(
                    item: item, joinDepth: joinDepth ?? joinReorderDepth(items: [item]))
                if let conform = item.conform {
                    videoPieces.append(try await ConformEngine.produceConformedPiece(
                        ffmpeg, source: item.source, conform: conform,
                        start: item.audioStart, end: item.audioEnd, work: work,
                        ext: pieceExts[i], clipIndex: i,
                        trackTimescale: exportTimescale, reorderDepth: depth,
                        onProgress: withinClip))
                } else {
                    // The planner already guarantees a field-coded item's plan is
                    // copy-only (`fieldCodedPlanNotCopyOnly`), so `item.fieldCoded` is
                    // passed through as the gated value — never re-derived from the
                    // codec here.
                    videoPieces.append(try await BoundaryReencodeEngine.produceVideoPiece(
                        ffmpeg, source: item.source, plan: item.segments, index: item.index,
                        encoder: item.encoder, work: work, ext: pieceExts[i], clipIndex: i,
                        codec: item.codec, trackTimescale: exportTimescale,
                        containerStart: item.containerStart, frameRate: item.frameRate,
                        sourceDamaged: item.sourceDamaged,
                        fieldCoded: item.fieldCoded, reorderDepth: depth,
                        onProgress: withinClip))
                }
                progress(0.7 * Double(i + 1) / Double(items.count))
            }
        }
        // The audio rebuild's expected output length: the clips' combined kept duration
        // (unknown if any clip lacks one — the mux fraction then just holds at 70 %).
        let totalSpan: Double? = items.reduce(0.0 as Double?) { acc, item in
            guard let acc, let d = keptDuration(item) else { return nil }
            return acc + d
        }

        // 2. Assemble the output(s).
        switch settings.mode {
        case .connect:
            var videoInput: URL? = nil
            if wantsVideo {
                if videoPieces.count == 1 {
                    // A lone piece feeds the final mux directly: with audio the mux
                    // itself rewrites it into the chosen container; video-only goes
                    // through the shared rewrap funnel (`containerReadyPiece`), which
                    // is the plain move for a container-native piece and the one-entry
                    // concat for a field-coded clip's `.ts` piece (issue #96).
                    videoInput = wantsAudio ? videoPieces[0]
                        : try await containerReadyPiece(videoPieces[0], ext: ext, item: items[0],
                                                        ffmpeg: ffmpeg, work: work,
                                                        name: "joined_video")
                } else {
                    let joined = work.appendingPathComponent("joined_video.\(ext)")
                    try await concatVideo(ffmpeg, pieces: videoPieces, items: items, to: joined, work: work)
                    videoInput = joined
                }
            }
            currentOutput = destination
            if wantsAudio {
                try await runFFmpeg(ffmpeg, audioMuxArguments(videoInput: videoInput, items: items, tracks: tracks, audioCodec: audioCodec, output: destination),
                                    failure: ExportError.concatFailed) { t in
                    progress(ExportProgress.muxFraction(
                        withinMux: ExportProgress.runFraction(outTime: t, expectedSeconds: totalSpan)))
                }
            } else {
                try placeFile(videoInput!, at: destination)
            }

        case .separate:
            // Each clip's file is the pre-computed `outputs` path (the same list the
            // collision guard checked); cut-only's audio-only outputs already follow each
            // clip's own codec/extension there, video outputs the global container's.
            for (i, item) in items.enumerated() {
                let out = outputs[i].url
                let videoInput = wantsVideo ? videoPieces[i] : nil
                let itemTracks = item.ownTracks ?? tracks
                currentOutput = out
                if wantsAudio {
                    try await runFFmpeg(ffmpeg, audioMuxArguments(videoInput: videoInput, items: [item], tracks: itemTracks, audioCodec: audioCodec, output: out),
                                        failure: ExportError.cutFailed) { t in
                        progress(ExportProgress.separateFraction(
                            clipIndex: i, clipCount: items.count,
                            withinMux: ExportProgress.runFraction(outTime: t, expectedSeconds: keptDuration(item))))
                    }
                } else {
                    // Video-only: the placed file must already be the chosen container,
                    // so the piece goes through the same rewrap funnel as connect mode.
                    try placeFile(try await containerReadyPiece(videoInput!, ext: ext, item: item,
                                                                ffmpeg: ffmpeg, work: work,
                                                                name: "rewrapped_\(i)"),
                                  at: out)
                }
                currentOutput = nil
                finishedFiles = i + 1
                progress(0.7 + 0.3 * Double(i + 1) / Double(items.count))
            }
        }
        } catch is CancellationError {
            // The mid-write file is partial — discard it. Finished separate files stay.
            if let currentOutput { try? FileManager.default.removeItem(at: currentOutput) }
            throw ExportError.cancelled(
                finished: finishedFiles,
                total: settings.mode == .separate ? items.count : 1)
        }
        progress(1.0)
    }

    /// The one rewrap funnel: a produced video piece that is placed (or fed onward)
    /// without an audio mux must already *be* the chosen container. A piece whose
    /// extension mismatches — a field-coded clip's `.ts` piece (issue #96) — is
    /// rewrapped through the same one-entry concat the multi-piece join uses (`.ts`
    /// pieces feeding TS/MKV/MP4 finals is the shell-validated recipe); a piece already
    /// in the container passes through untouched, keeping today's plain move
    /// byte-identical.
    private static func containerReadyPiece(_ piece: URL, ext: String, item: ExportItem,
                                            ffmpeg: URL, work: URL, name: String) async throws -> URL {
        guard piece.pathExtension.lowercased() != ext.lowercased() else { return piece }
        let rewrapped = work.appendingPathComponent("\(name).\(ext)")
        try await concatVideo(ffmpeg, pieces: [piece], items: [item], to: rewrapped, work: work)
        return rewrapped
    }

    private static func concatVideo(_ ffmpeg: URL, pieces: [URL], items: [ExportItem], to output: URL, work: URL) async throws {
        let listFile = work.appendingPathComponent("concat-\(UUID().uuidString).txt")
        try concatListContents(pieces: pieces, durations: crossClipDurations(items: items))
            .write(to: listFile, atomically: true, encoding: .utf8)
        try await runFFmpeg(ffmpeg, concatArguments(listFile: listFile, output: output), failure: ExportError.concatFailed)
    }

    /// File names for `.separate` mode, one per clip in timeline order (issue #30):
    /// `NN <clip name>.<ext>` — `NN` is the 1-based position zero-padded to the digit
    /// count of the clip total (minimum two, so Finder's alphabetical sort is the
    /// timeline order even as clips are added later).
    static func separateFileNames(clipNames: [String], ext: String) -> [String] {
        separateFileNames(clipNames: clipNames, exts: Array(repeating: ext, count: clipNames.count))
    }

    /// Per-clip-extension variant: cut-only audio-only outputs follow each clip's own
    /// codec, so their extensions can differ within one export (ADR-0018).
    static func separateFileNames(clipNames: [String], exts: [String]) -> [String] {
        var taken = Set<String>()
        return clipNames.enumerated().map { i, name in
            separateFileName(clipName: name, position: i + 1, count: clipNames.count,
                             ext: exts[i], taken: &taken)
        }
    }

    /// One `.separate`-mode file name: the clip's display name loses its source
    /// extension, `/` and `:` become `-` (the two characters the filesystem and Finder
    /// fight over), and the padded position is prefixed — always, even for a single
    /// clip, so the names sort predictably. Distinct prefixes make collisions
    /// impossible, but if one happens anyway a `-2`, `-3`, … suffix keeps the names
    /// unique rather than silently merging two clips into one file.
    static func separateFileName(clipName: String, position: Int, count: Int,
                                 ext: String, taken: inout Set<String>) -> String {
        var stem = (clipName as NSString).deletingPathExtension
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        if stem.isEmpty { stem = "Clip" }
        let width = max(2, String(count).count)
        let prefix = String(format: "%0\(width)d", position)
        var name = "\(prefix) \(stem).\(ext)"
        var n = 2
        while taken.contains(name) {
            name = "\(prefix) \(stem)-\(n).\(ext)"
            n += 1
        }
        taken.insert(name)
        return name
    }

    /// Moves a produced file to its destination, replacing any existing file.
    private static func placeFile(_ src: URL, at dest: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: src, to: dest)
    }

    /// Runs ffmpeg and turns a non-zero exit into `failure(stderr)`. With `onOutTime` the
    /// run also streams `-progress pipe:1` (issue #9), reporting each block's out_time
    /// seconds as it arrives.
    private static func runFFmpeg(_ ffmpeg: URL, _ args: [String], failure: (String) -> ExportError,
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
            throw failure(String(data: result.stderr, encoding: .utf8) ?? "exit \(result.status)")
        }
    }
}
