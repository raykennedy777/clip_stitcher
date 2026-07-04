import Foundation

/// Finds a source's damage zones at import (issue #45). Three stages, all cheap:
///
/// 1. **Demux anomaly pass** (pure) over the all-streams packet read the index
///    already does: video DTS gaps (cadence breaks), packets with no timestamp at
///    all (truncated pictures), duplicate-DTS bursts (garbled PES headers), and
///    audio PTS gaps in any audio stream. Audio gaps matter for video too — on the
///    real capture every video damage event has a companion audio gap, including
///    events with no video packet trace.
/// 2. **Windowed confirm decodes** — a short seek-anchored decode around each
///    candidate cluster, parsing the decoder's `corrupt decoded frame` reports
///    correlated with showinfo's per-frame timestamps, plus one last-GOP window for
///    an EOF-truncated final frame.
/// 3. **Never a from-start full decode**: on sources whose keyframes are non-IDR
///    recovery points, corrupt flags avalanche after the first damage event (43 % of
///    all frames flagged on the real capture, pixel-identical to a fresh-seek decode
///    — checksum-proven). Only seek-anchored windows give local truth.
///
/// The thresholds (gap ≥ 1.8× the stream's median interval, duplicate ≤ 0.25×,
/// 2 s cluster merge) reproduce every documented zone of both real corrupted
/// captures and flag nothing on the clean fixtures — including the broadcast capture,
/// whose ~714 benign anomalies are pts-only (dts intact, so no rule fires).
enum DamageDetector {
    // MARK: - Stage 1: demux anomaly pass (pure)

    /// One demux-level irregularity, in absolute presentation seconds.
    struct Anomaly: Equatable {
        var start: Double
        var end: Double
        var isVideo: Bool
        /// Whether this is a *video gap* — a long inter-dts interval — whose claim to be
        /// **video** damage a confirm decode must corroborate. A clean cadence change
        /// produces such gaps without losing any picture: Clip Doctor's own output splices a
        /// PAFF copy-head (two field packets per frame) onto an MBAFF re-encoded tail (one
        /// packet per frame), and the tail's every-frame interval reads as a gap against the
        /// head-dominated global median, even though the decoder passes straight through it.
        /// A duplicate-DTS burst or a timestamp-less truncated picture leaves this `false`:
        /// that is decoder-invisible demux evidence (the 39 s dead zone's signature), trusted
        /// as video damage without a decode. Irrelevant for audio anomalies (always `false`).
        var needsDecodeConfirm: Bool = false
    }

    /// A cluster of anomalies — the unit a confirm decode investigates.
    struct Candidate: Equatable {
        var start: Double
        var end: Double
        var hasVideoAnomaly: Bool
        /// A video anomaly the decoder can't see — a duplicate-DTS burst or a timestamp-less
        /// truncated picture — so it stands as video damage on its own, no decode needed.
        var hasOpaqueVideoAnomaly: Bool = false
        /// An audio pts gap somewhere in the cluster — keeps the zone as an audio-only event
        /// when the video evidence is gap-only and the decode comes back clean.
        var hasAudioAnomaly: Bool = false
    }

    /// Streams with fewer intervals than this have no meaningful cadence to break.
    private static let minIntervals = 30

    /// How far past a candidate's end the confirm decode runs *and* its damage span is judged —
    /// one shared bound so a late-resume hole the PS-seek slack pushes past the candidate end is
    /// both decoded and judged (issue #80). Wide enough to cover the seek landing slack, tight
    /// enough to keep the confirm decode short.
    private static let tailLookahead = 1.5

    static func anomalies(streams: [FrameIndexer.StreamPackets]) -> [Anomaly] {
        var found: [Anomaly] = []
        for stream in streams {
            if stream.isVideo {
                // Cadence off the **dts in demux order** — presentation reorder would
                // hide a hole behind B-frame interleaving. dts only: Matroska stores
                // no dts, so ffprobe leaves the first reorder-depth packets "N/A" and
                // synthesizes the rest — a dts-less packet *with* a pts is that benign
                // placeholder, and splicing its pts into the dts sequence fabricates a
                // gap+dup pair at the file head (caught on the clean H.264/HEVC
                // fixtures). A packet with **neither** stamp is damage — the truncated
                // pictures the real capture carries — timed at the last seen stamp.
                var seq: [Double] = []
                for p in stream.packets {
                    if let t = p.dts {
                        seq.append(t)
                    } else if p.pts == nil, let last = seq.last {
                        found.append(Anomaly(start: last, end: last, isVideo: true))
                    }
                }
                if let median = medianInterval(seq) {
                    let deltas = zip(seq.dropFirst(), seq).map { $0 - $1 }
                    found += videoGapAnomalies(seq: seq, deltas: deltas, median: median)
                    // Duplicate-DTS bursts (garbled PES headers): micro-increment steps the
                    // demuxer synthesizes, decoder-invisible, so no confirm — the 39 s dead
                    // zone's signature. Disjoint from the gap band above.
                    for (i, d) in deltas.enumerated() where d <= median * 0.25 {
                        found.append(Anomaly(start: min(seq[i], seq[i + 1]),
                                             end: max(seq[i], seq[i + 1]), isVideo: true))
                    }
                } else {
                    // A dts-poor container (e.g. a raw elementary stream): fall back
                    // to presentation order, gaps only — sorted pts legitimately
                    // duplicates on timestamp-dirty sources (the broadcast capture), so the
                    // duplicate rule stays dts-exclusive.
                    let pts = stream.packets.compactMap(\.pts).sorted()
                    guard let median = medianInterval(pts) else { continue }
                    let deltas = zip(pts.dropFirst(), pts).map { $0 - $1 }
                    found += videoGapAnomalies(seq: pts, deltas: deltas, median: median)
                }
            } else {
                // Audio reads presentation gaps: a pts hole is missing sound whatever
                // the packet order.
                let seq = stream.packets.compactMap { $0.pts ?? $0.dts }.sorted()
                guard let median = medianInterval(seq) else { continue }
                for (i, d) in zip(seq.dropFirst(), seq).map({ $0 - $1 }).enumerated()
                where d >= median * 1.8 {
                    found.append(Anomaly(start: seq[i], end: seq[i] + d, isVideo: false))
                }
            }
        }
        return found.sorted { $0.start < $1.start }
    }

    /// Merges anomalies within `mergeDistance` seconds into candidate zones. The real
    /// captures' multi-hit events (two holes 0.4 s apart; a 39 s run of hundreds of
    /// audio errors) each merge to one candidate, while distinct events hundreds of
    /// seconds apart stay separate.
    static func clusterCandidates(_ anomalies: [Anomaly],
                                  mergeDistance: Double = 2.0) -> [Candidate] {
        var clusters: [Candidate] = []
        for a in anomalies.sorted(by: { $0.start < $1.start }) {
            let opaqueVideo = a.isVideo && !a.needsDecodeConfirm
            if var last = clusters.last, a.start - last.end <= mergeDistance {
                last.end = max(last.end, a.end)
                last.hasVideoAnomaly = last.hasVideoAnomaly || a.isVideo
                last.hasOpaqueVideoAnomaly = last.hasOpaqueVideoAnomaly || opaqueVideo
                last.hasAudioAnomaly = last.hasAudioAnomaly || !a.isVideo
                clusters[clusters.count - 1] = last
            } else {
                clusters.append(Candidate(start: a.start, end: a.end,
                                          hasVideoAnomaly: a.isVideo,
                                          hasOpaqueVideoAnomaly: opaqueVideo,
                                          hasAudioAnomaly: !a.isVideo))
            }
        }
        return clusters
    }

    /// Video gap anomalies from a timestamp sequence (dts in demux order, or sorted pts on a
    /// dts-poor container), in two bands the confirm decode later arbitrates:
    ///
    /// - **Sharp holes** — a single step that beats even the *local* cadence
    ///   (`1.8 × max(global, local)`). `max(global, local)` lifts the bar where the stream
    ///   genuinely runs slower and never lowers it: Clip Doctor's own output splices a PAFF
    ///   copy-head (two field packets per frame) onto an MBAFF re-encoded tail (one packet per
    ///   frame), so every normal tail step is ~2× the head-dominated file median — the bare
    ///   global rule would flag the whole tail (a file-long candidate, a multi-minute confirm
    ///   decode). A dup-burst region that *collapses* the local median (the 39 s dead zone)
    ///   falls back to the global bar, unchanged.
    /// - **Sustained slow regions** — the failure mode `max(global, local)` alone introduced
    ///   (issue #80). A region of moderate gaps ≥ half the `localMedian` window (e.g. an
    ///   every-other-frame dropout, steps ≈ 2× cadence) fills its *own* window, so `localMedian`
    ///   becomes the elevated value and the bar rises above the very gaps that are the damage —
    ///   with no dup burst, truncated picture, or audio companion, the zone would be missed
    ///   entirely. A run of consecutive steps that clear the global bar but were suppressed by
    ///   the local gate is emitted as **one** gap candidate for the decode to confirm — *iff* it
    ///   is a **bounded excursion**: it does not reach the last delta and the cadence *returns to
    ///   the file baseline* (a normal step follows). A run that instead runs to EOF, or hands off
    ///   to another hole rather than returning to baseline, is the permanent PAFF→MBAFF cadence
    ///   change (the slower tail is the new normal), left suppressed. The run-length floor is the
    ///   local half-window: any shorter region cannot inflate its own local median, so the sharp
    ///   band already caught it — the floor keeps the two bands from double-emitting.
    static func videoGapAnomalies(seq: [Double], deltas: [Double], median: Double,
                                  window: Int = 201) -> [Anomaly] {
        var found: [Anomaly] = []
        var runStart: Int? = nil   // start delta-index of the current suppressed-gap run
        func closeRun(before endExclusive: Int) {
            guard let rs = runStart else { return }
            runStart = nil
            guard endExclusive - rs >= window / 2,          // long enough to have inflated its own local median
                  endExclusive < deltas.count,              // content resumes (not the run-to-EOF PAFF tail)
                  deltas[endExclusive] < median * 1.8        // and resumes at the file baseline cadence
            else { return }
            found.append(Anomaly(start: seq[rs], end: seq[endExclusive], isVideo: true,
                                 needsDecodeConfirm: true))
        }
        for (i, d) in deltas.enumerated() {
            if d >= median * 1.8 {
                if d >= 1.8 * Swift.max(median, localMedian(deltas, around: i, window: window)) {
                    closeRun(before: i)     // a sharp hole ends any slow run (not a return to baseline)
                    found.append(Anomaly(start: seq[i], end: seq[i] + d, isVideo: true,
                                         needsDecodeConfirm: true))
                } else if runStart == nil {
                    runStart = i
                }
            } else {
                closeRun(before: i)
            }
        }
        closeRun(before: deltas.count)
        return found
    }

    /// The local interval cadence around `index`: the median of the deltas in a window
    /// centred on it. Used only to *raise* the gap bar where the stream legitimately runs at
    /// a slower cadence than the file-wide median — a PAFF copy-head spliced to an MBAFF
    /// re-encoded tail (Clip Doctor's own output) runs at half the packet rate, so every
    /// normal tail step is ~2× the head-dominated median and would otherwise flood the tail
    /// with gaps. Called only for steps that already cleared the global bar, so it stays off
    /// the hot path. A centred window means a tail step's window is tail-majority — the local
    /// cadence reads as the tail's own, leaving the transition with at most a couple of
    /// anomalies instead of one per frame. Returns 0 when the window is too thin, so
    /// `max(global, local)` falls back to the file-wide median.
    static func localMedian(_ deltas: [Double], around index: Int, window: Int = 201) -> Double {
        let half = window / 2
        let lo = max(0, index - half), hi = min(deltas.count - 1, index + half)
        guard hi - lo >= 8 else { return 0 }
        let slice = deltas[lo...hi].sorted()
        return slice[slice.count / 2]
    }

    /// The median interval between consecutive values; nil when too thin to call.
    static func medianInterval(_ seq: [Double]) -> Double? {
        guard seq.count > minIntervals else { return nil }
        let deltas = zip(seq.dropFirst(), seq).map { $0 - $1 }
        let median = deltas.sorted()[deltas.count / 2]
        return median > 0 ? median : nil
    }

    /// A confirm window's frame cadence measured on its **clean margins** — the
    /// decoded frames before and after the candidate span, whose deltas never cross
    /// it. nil when the margins are too thin to call (then the caller falls back to
    /// the whole-window median, then the index interval).
    static func marginInterval(frames: [DecodedFrame], candidate: Candidate) -> Double? {
        var deltas: [Double] = []
        for region in [frames.filter { $0.pts < candidate.start - 0.2 },
                       frames.filter { $0.pts > candidate.end + 0.2 }] {
            deltas += zip(region.dropFirst(), region).map { $0.pts - $1.pts }
        }
        guard deltas.count >= 8 else { return nil }
        let median = deltas.sorted()[deltas.count / 2]
        return median > 0 ? median : nil
    }

    // MARK: - Stage 2: confirm-decode parsing (pure)

    /// One frame a confirm decode emitted: its showinfo pts (window-relative) and
    /// whether the decoder flagged it.
    struct DecodedFrame: Equatable {
        var pts: Double
        var corrupt: Bool
    }

    /// Reads a `-vf showinfo` run's stderr into the decoded frame list. The decoder's
    /// damage reports (`corrupt decoded frame`, a packet-level decode error) print
    /// *before* the frame's showinfo line, so each marker flags the next frame.
    static func parseConfirmDecode(stderr: String) -> [DecodedFrame] {
        var frames: [DecodedFrame] = []
        var corruptNext = false
        stderr.enumerateLines { line, _ in
            if line.contains("corrupt decoded frame")
                || line.contains("Error submitting packet to decoder") {
                corruptNext = true
            }
            guard line.contains("Parsed_showinfo"),
                  let range = line.range(of: "pts_time:") else { return }
            let tail = line[range.upperBound...]
            guard let pts = Double(tail.prefix(while: { !$0.isWhitespace })) else { return }
            frames.append(DecodedFrame(pts: pts, corrupt: corruptNext))
            corruptNext = false
        }
        return frames
    }

    /// The damaged video span inside `window` (absolute seconds), from a confirm
    /// decode's frames (already mapped to absolute time): corrupt frames, and holes
    /// where consecutive decoded frames sit ≥ 1.8 frame intervals apart. The span
    /// runs from just past the last good frame to where good content resumes — the
    /// bounds a time-window select can drop directly. `nil` when the window decoded
    /// clean (an audio-only event).
    static func videoDamageSpan(frames: [DecodedFrame], window: ClosedRange<Double>,
                                frameInterval: Double) -> (start: Double, end: Double)? {
        var start: Double? = nil
        var end: Double? = nil
        func extend(_ s: Double, _ e: Double) {
            start = min(start ?? s, s)
            end = max(end ?? e, e)
        }
        for (i, frame) in frames.enumerated() {
            if frame.corrupt, window.contains(frame.pts) {
                extend(frame.pts - frameInterval / 2, frame.pts + frameInterval / 2)
            }
            guard i + 1 < frames.count else { continue }
            let d = frames[i + 1].pts - frame.pts
            if d >= frameInterval * 1.8, window.contains(frame.pts + d / 2) {
                extend(frame.pts + frameInterval / 2, frames[i + 1].pts - frameInterval / 2)
            }
        }
        guard let s = start, let e = end else { return nil }
        return (s, e)
    }

    /// The damage zone a confirmed candidate yields — or `nil` to drop it. Pure, so the
    /// gap-vs-opaque authority rule is unit-tested without ffmpeg.
    ///
    /// The confirm decode is the authority on **video** damage. A candidate is real video
    /// damage when the decode corroborates it (`span` — corrupt frames or decoded holes) or
    /// when it carries decoder-invisible demux evidence (`hasOpaqueVideoAnomaly` — a
    /// duplicate-DTS burst or a truncated picture, which the decoder silently absorbs). A
    /// candidate whose only video evidence is **gaps** that the decode passed through clean is
    /// *not* video damage — a clean cadence change (Clip Doctor's PAFF head → MBAFF tail) trips
    /// the gap rule without losing picture. Such a candidate degrades to its audio evidence:
    /// an audio-only zone if a companion audio gap is present, otherwise nothing at all.
    ///
    /// `decodedFrameCount == 0` means the confirm decode produced nothing (a kill, a missing
    /// binary) — it can't veto a gap it never looked at, so a gap candidate stays video damage.
    static func resolveZone(candidate: Candidate, span: (start: Double, end: Double)?,
                            decodedFrameCount: Int, containerStart: Double,
                            frameInterval: Double) -> DamageZone? {
        let videoReal = span != nil
            || candidate.hasOpaqueVideoAnomaly
            || (candidate.hasVideoAnomaly && decodedFrameCount == 0)
        if videoReal {
            return nonZeroWidth(DamageZone(
                start: min(candidate.start, span?.start ?? .infinity) - containerStart,
                end: max(candidate.end, span?.end ?? -.infinity) - containerStart,
                affectsVideo: true), frameInterval: frameInterval)
        }
        guard candidate.hasAudioAnomaly else { return nil }
        return nonZeroWidth(DamageZone(start: candidate.start - containerStart,
                                       end: candidate.end - containerStart, affectsVideo: false),
                            frameInterval: frameInterval)
    }

    /// Guarantees a zone is never zero-width — the invariant every emission point upholds so
    /// nothing downstream ever plans around a span with no frames in it. A truncated ending
    /// (a partial final frame the recording cut off) and a timestamp-less truncated picture
    /// both surface as `start == end`; each is really the one incomplete frame, so the zone is
    /// widened to span a single frame interval (CONTEXT.md "Truncated ending"). A zone already
    /// at least one interval wide is returned unchanged.
    static func nonZeroWidth(_ zone: DamageZone, frameInterval: Double) -> DamageZone {
        guard zone.end - zone.start < frameInterval else { return zone }
        return DamageZone(start: zone.start, end: zone.start + frameInterval,
                          affectsVideo: zone.affectsVideo)
    }

    // MARK: - Orchestration

    /// Detects a clip's damage zones: cluster the demux anomalies, confirm each
    /// cluster with a seek-anchored windowed decode, and run the last-GOP EOF check.
    /// Returned zones are in source seconds from the container start (`DamageZone`),
    /// sorted. Detection failures degrade to "no zones found", never a failed import.
    static func detectZones(url: URL, scan: FrameIndexer.AllStreamsScan,
                            containerStart: Double) async -> [DamageZone] {
        let index = scan.index
        guard index.count > minIntervals,
              let interval = medianInterval(index.pts),
              let ffmpeg = try? FFTools.ffmpegURL() else { return [] }

        var zones: [DamageZone] = []
        for candidate in clusterCandidates(anomalies(streams: scan.streams)) {
            // Seek two keyframes back from the cluster: one GOP of margin plus one
            // more because MPEG-PS time-seek is byte-estimated and lands late even on
            // clean data (issue #43 de-risk) — `t` in the decode stays anchored to the
            // *requested* time, so the landing slack only widens coverage.
            let anchorFrame = index.frameIndex(atOrBeforeTime: candidate.start - 0.5)
            // No keyframe at/before the anchor → seek from the file head (frame 0); a
            // decode from the earliest frame still covers the candidate span.
            var keyframe = index.keyframeIndex(atOrBefore: anchorFrame) ?? 0
            keyframe = index.keyframeIndex(atOrBefore: max(0, keyframe - 1)) ?? 0
            let seekPts = index.pts[keyframe]
            // The decode must reach as far as the span is judged (`tailLookahead` below): a hole
            // whose resume frame lands in the PS-seek slack past the candidate end is invisible
            // unless the decode actually produced frames out there. Decoding only to +1.0 while
            // judging to +1.5 left no frame past a late resume — the span came back nil and
            // `resolveZone`'s clean-decode veto silently dropped a corroborated dropout (#80).
            let windowEnd = candidate.end + tailLookahead
            guard windowEnd > seekPts else { continue }

            let frames = await confirmDecode(
                ffmpeg, url: url, seek: seekPts - containerStart,
                duration: windowEnd - seekPts)
            let absolute = frames.map { DecodedFrame(pts: $0.pts + seekPts, corrupt: $0.corrupt) }
            // Hole detection judges against the *decoded* frames' cadence, never the
            // index's packet cadence: on a field-coded (PAFF) source the index runs at
            // 2× the decoder's frame rate (issue #46), and the packet-derived interval
            // would make every normal frame step read as a hole. Measured on the
            // window's clean margins — inside the candidate the damaged frames' own
            // garbled timing would skew it (the 39 s dead zone emitted at half the
            // real interval and turned the whole window into "holes").
            let local = marginInterval(frames: absolute, candidate: candidate)
                ?? medianInterval(absolute.map(\.pts)) ?? interval
            let span = videoDamageSpan(
                frames: absolute,
                window: (candidate.start - 1.0)...(candidate.end + tailLookahead),
                frameInterval: local)
            // The decode is the authority on video damage (corrupt frames, holes); demux-level
            // duplicate-DTS bursts and truncated pictures are trusted on their own (the 39 s
            // dead zone decodes clean but its dup bursts are real video damage); a gap the
            // decode passed through clean is a cadence change, not lost picture, so it degrades
            // to its audio evidence or drops. (`resolveZone`.)
            if let zone = resolveZone(candidate: candidate, span: span,
                                      decodedFrameCount: absolute.count,
                                      containerStart: containerStart, frameInterval: local) {
                zones.append(zone)
            }
        }

        if let eof = await eofZone(ffmpeg, url: url, index: index,
                                   frameInterval: interval, containerStart: containerStart) {
            // An EOF zone that touches the last cluster merges into it (both describe
            // the same dying seconds of the file).
            if var last = zones.last, eof.start - last.end <= 2.0 {
                last.end = max(last.end, eof.end)
                last.affectsVideo = last.affectsVideo || eof.affectsVideo
                zones[zones.count - 1] = last
            } else {
                zones.append(eof)
            }
        }
        return zones.sorted { $0.start < $1.start }
    }

    /// The last-GOP check: an EOF-truncated final frame leaves **no inter-packet gap**
    /// (there is no next packet), so the demux pass can't see it — only a decode of
    /// the file's tail can. Decodes from three keyframes back (PS landing margin) and
    /// reports a zone when tail frames come out corrupt-flagged or the decoder emits
    /// fewer frames than the index holds.
    ///
    /// Deliberately **no pts-hole detection here**: a stream-copy `-t` cut keeps a
    /// decode-order prefix of a B-pyramid, so a legitimately cut tail *presents* with
    /// missing slots while its demuxed dts runs clean (the HEVC fixture's last frames
    /// — index and decode agree). A real packet hole near EOF still shows up as a dts
    /// gap in the demux pass.
    private static func eofZone(_ ffmpeg: URL, url: URL, index: FrameIndex,
                                frameInterval: Double, containerStart: Double) async -> DamageZone? {
        guard let lastPts = index.pts.last else { return nil }
        // No keyframe at/before the last frame → seek from the file head (frame 0).
        var keyframe = index.keyframeIndex(atOrBefore: index.count - 1) ?? 0
        for _ in 0..<2 { keyframe = index.keyframeIndex(atOrBefore: max(0, keyframe - 1)) ?? 0 }
        let seekPts = index.pts[keyframe]
        guard lastPts > seekPts else { return nil }

        let frames = await confirmDecode(
            ffmpeg, url: url, seek: seekPts - containerStart, duration: nil)
        guard !frames.isEmpty else { return nil }
        let absolute = frames.map { DecodedFrame(pts: $0.pts + seekPts, corrupt: $0.corrupt) }
        // Decoded-local cadence, like the candidate windows: a field-coded source's
        // index runs at 2× the decoder's frame rate.
        let local = medianInterval(absolute.map(\.pts)) ?? frameInterval
        return eofZoneFromDecode(frames: absolute, lastPts: lastPts, seekPts: seekPts,
                                 localInterval: local, containerStart: containerStart)
    }

    /// The truncated-ending zone from an EOF confirm decode's frames (already mapped to
    /// absolute time). Pure, so the truncation math is unit-tested without ffmpeg. Two
    /// signatures of a cut-off final frame: a corrupt-flagged tail frame, or a **dropped**
    /// final frame that ends the decode a full frame short of the last index pts (threshold ¾
    /// of a decoded interval — a field-coded source's index legitimately ends half an interval
    /// past the last decoded frame, its final frame's second field, which must stay quiet).
    /// The zone is a real one-frame video zone reaching the file end (never zero-width,
    /// CONTEXT.md "Truncated ending"), so the repair trims to the last complete frame. `nil`
    /// when the tail decoded clean all the way to the last index frame.
    static func eofZoneFromDecode(frames: [DecodedFrame], lastPts: Double, seekPts: Double,
                                  localInterval local: Double, containerStart: Double) -> DamageZone? {
        var span: (start: Double, end: Double)? = nil
        for frame in frames where frame.corrupt && frame.pts >= seekPts {
            span = (min(span?.start ?? .infinity, frame.pts - local / 2),
                    max(span?.end ?? -.infinity, frame.pts + local / 2))
        }
        if let lastDecoded = frames.last?.pts, lastDecoded < lastPts - local * 0.75 {
            let missingStart = lastDecoded + local / 2
            span = (min(span?.start ?? missingStart, missingStart),
                    max(span?.end ?? 0, lastPts + local))
        }
        guard let s = span else { return nil }
        return nonZeroWidth(DamageZone(start: s.start - containerStart, end: s.end - containerStart,
                                       affectsVideo: true), frameInterval: local)
    }

    /// One seek-anchored confirm decode: video only, showinfo for per-frame
    /// timestamps, stderr carries the decoder's damage reports. A `nil` duration
    /// reads to the file's end (the EOF window). stderr streams to a temp **file**
    /// because `parseConfirmDecode` reads *every* per-frame showinfo line — the whole
    /// stream is data here, not a failure tail, so it must not go through
    /// `ProcessRunner`'s bounded in-memory stderr tail (issue #59), which would drop the
    /// early frames of a long EOF window and corrupt the decoded-frame list.
    /// Errors (a kill, a missing binary) return no frames — the candidate then
    /// records as an audio-only zone rather than failing the import.
    private static func confirmDecode(_ ffmpeg: URL, url: URL, seek: Double,
                                      duration: Double?) async -> [DecodedFrame] {
        var args = ["-v", "info", "-ss", ExportEngine.timeString(max(0, seek))]
        if let duration { args += ["-t", ExportEngine.timeString(duration)] }
        args += ["-i", url.path, "-map", "0:v:0", "-vf", "showinfo", "-f", "null", "-"]
        let dump = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-confirm-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: dump) }
        guard (try? await ProcessRunner.run(ffmpeg, args, stderrTo: dump)) != nil,
              let stderr = try? String(contentsOf: dump, encoding: .utf8) else { return [] }
        return parseConfirmDecode(stderr: stderr)
    }
}
