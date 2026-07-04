import SwiftUI
import AppKit

enum ClipRole {
    case target
    case smartRender
    case reEncode
    case cutOnly
    case unknown

    /// The badge a source row shows. The target row always keeps its Target badge —
    /// the designation survives cut-only untouched (ADR-0018). Separate + cut-only
    /// marks every other row "Cut only": the verdict is unconditional, no target
    /// comparison, so no probed video is needed. Every other mode×rendering
    /// combination is the match verdict against the target.
    nonisolated static func role(for clip: Clip, target: Clip?, output: OutputSettings) -> ClipRole {
        if clip.id == target?.id { return .target }
        if output.mode == .separate && output.rendering == .cutOnly { return .cutOnly }
        guard let target, clip.video != nil else { return .unknown }
        return MatchEvaluator.matches(clip, target: target) ? .smartRender : .reEncode
    }

    /// The badge's visible text — also exposed as the badge's accessibility value
    /// so external probes can assert the per-clip verdict (issue #5).
    nonisolated var badgeText: String? {
        switch self {
        case .target: return "Target"
        case .smartRender: return "Smart render"
        case .reEncode: return "Re-encode"
        case .cutOnly: return "Cut only"
        case .unknown: return nil
        }
    }
}

struct ClipRowView: View {
    let position: Int
    let clip: Clip
    let role: ClipRole
    let state: ImportState
    /// The clip's resolved source URL — nil while unresolved or source-missing,
    /// which keeps the generic placeholder in the thumbnail box.
    let url: URL?
    /// The clip's planned copy/re-encode split (issue #15) — nil until the frame
    /// index is built, which hides the share quietly.
    var share: ExportPlanner.CopyShare? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(position)")
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)

            ClipThumbnailView(url: url, seconds: selectionStartSeconds)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(clip.displayName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    roleBadge
                }
                Text(Self.detailLine(for: clip))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                statusLine
                fieldCodedWarning
                damageLine
                selectionLine
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Badges

    @ViewBuilder
    private var roleBadge: some View {
        switch role {
        case .target:
            badge("Target", systemImage: "target", color: .accentColor)
        case .smartRender:
            badge("Smart render", systemImage: "bolt", color: .green)
        case .reEncode:
            badge("Re-encode", systemImage: "arrow.triangle.2.circlepath", color: .orange)
        case .cutOnly:
            badge("Cut only", systemImage: "scissors", color: .blue)
        case .unknown:
            EmptyView()
        }
    }

    private func badge(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            // Position is 1-based for display; AX identifiers are 0-based timeline
            // indices to match `source.clip.<index>` on the row (issue #5).
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("source.clip.\(position - 1).role")
            .accessibilityLabel("Role")
            .accessibilityValue(Text(text))
    }

    // MARK: - Detail / status

    /// The one-line media summary under the clip name. Pure and nonisolated so the
    /// audio rules (issue #11: edited track list, not probed streams) are unit-testable.
    nonisolated static func detailLine(for clip: Clip) -> String {
        guard let v = clip.video else { return "Reading…" }
        var parts: [String] = ["\(v.codec.uppercased()) \(v.width)×\(v.height)"]
        if !v.frameRate.isEmpty, v.frameRate != "0/0" {
            parts.append("\(formattedFrameRate(v.frameRate)) fps")
        }
        if let order = v.fieldOrder {
            // Lowercase row style, only shown when the source carries a field order. Classifies
            // through the shared `MediaFormatting.isProgressive` so an ambiguous "unknown" reads
            // "progressive" here exactly as the inspector's scan-type does (was "interlaced
            // (unknown)"), the two can no longer drift.
            parts.append(MediaFormatting.isProgressive(order) ? "progressive" : "interlaced (\(order))")
        }
        // The edited track list (ADR-0014 slots), not the file's probed streams.
        let tracks = clip.effectiveAudioTracks
        if let a = tracks.first ?? nil {
            parts.append("\(a.codec.uppercased()) \(a.channels)ch \(a.sampleRate / 1000)kHz")
            if tracks.count > 1 {
                parts.append("\(tracks.count) audio tracks")
            }
        } else if !tracks.isEmpty {
            // First slot's properties are unknown (e.g. unprobed external): no codec
            // to describe, but the audio must stay visible.
            parts.append(tracks.count == 1 ? "1 audio track" : "\(tracks.count) audio tracks")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state {
        case .probing:
            Label("Reading properties…", systemImage: "magnifyingglass")
                .font(.caption).foregroundStyle(.secondary)
        case .indexing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Indexing frames…").font(.caption).foregroundStyle(.secondary)
            }
        case .ready:
            if let frames = clip.frameCount, let duration = clip.duration {
                HStack(spacing: 4) {
                    Text("\(frames) frames · \(formattedDuration(duration))")
                    // With a selection the share rides the selection line below instead,
                    // so it renders exactly once per row.
                    if clip.inPoint == nil, clip.outPoint == nil, let text = shareText {
                        shareBadge(text)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        case .sourceMissing:
            Label("Source missing — select the clip and use Relink…", systemImage: "questionmark.folder")
                .font(.caption).foregroundStyle(.red).lineLimit(2)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    /// The field-coded (PAFF) warning (issue #46): the source stores two field
    /// pictures per displayed frame. For H.264 field-coded clips, cutting is supported but
    /// cut points snap to clean keyframes (slice 5 of issue #96). For other codecs, the app’s
    /// frame numbering — and with it frame-accurate cutting and joining — is off by 2× on this file.
    /// Clip Doctor can still repair it (issue #54, a damage-to-EOF re-encode).
    /// Plain language; warn-only, nothing is blocked.
    @ViewBuilder
    private var fieldCodedWarning: some View {
        if clip.fieldCoded == true {
            let message = FieldCodedSupport.requiresCopyOnlyCuts(fieldCoded: clip.fieldCoded, codec: clip.video?.codec)
                ? "Cut points snap to the nearest clean keyframe on this clip."
                : "This file stores two half-pictures per frame — frame-accurate cutting and joining aren’t supported for it yet (Clip Doctor can still repair it)."
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("source.clip.\(position - 1).fieldCoded")
                .accessibilityLabel("Field-coded warning")
        }
    }

    /// The clip's damage zones found at import (issue #45): count and positions, so
    /// the user knows where their capture is hurt. Detection-only for now — the
    /// repair slices (#47/#48) will act on the same zones.
    @ViewBuilder
    private var damageLine: some View {
        if let text = Self.damageLineText(zones: clip.damageZones) {
            Label(text, systemImage: "bandage")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("source.clip.\(position - 1).damage")
                .accessibilityLabel("Damage zones")
                .accessibilityValue(Text(text))
        }
    }

    /// The damage line's text: zone count plus their positions as clip time, capped
    /// at six so a badly hurt capture doesn't flood the row. Nil hides the line —
    /// no zones found, or the clip predates detection. Pure for unit tests.
    nonisolated static func damageLineText(zones: [DamageZone]?) -> String? {
        guard let zones, !zones.isEmpty else { return nil }
        // The shared formatter keeps the row and the export's repair report agreeing
        // about every zone's position (issue #47).
        let shown = zones.prefix(6).map { ExportPlanner.formattedClipTime($0.start) }
        let times = shown.joined(separator: ", ") + (zones.count > 6 ? ", …" : "")
        return zones.count == 1
            ? "Damage zone at \(times)"
            : "\(zones.count) damage zones at \(times)"
    }

    /// Shown only when the clip has a selection narrower than the whole clip.
    @ViewBuilder
    private var selectionLine: some View {
        if clip.inPoint != nil || clip.outPoint != nil {
            let inFrame = clip.inPoint ?? 0
            let outFrame = clip.outPoint ?? max(0, (clip.frameCount ?? 1) - 1)
            HStack(spacing: 4) {
                Label("In \(inFrame) – Out \(outFrame) · \(max(0, outFrame - inFrame + 1)) frames", systemImage: "scissors")
                if let text = shareText {
                    shareBadge(text)
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.tint)
        }
    }

    /// The quiet per-clip copied-share readout (issue #15), e.g. "92% copied" —
    /// "0% copied" is the open-GOP poster child (no copy-safe cut points at all).
    private var shareText: String? {
        share.map { Self.copiedShareText(fraction: $0.copiedFraction) }
    }

    /// Formats a copied fraction for the row. Rounds to whole percent, but never
    /// rounds a partial share *up* to 100% — claiming "100% copied" while boundary
    /// slivers re-encode would repeat the lie the Output footer used to tell.
    nonisolated static func copiedShareText(fraction: Double) -> String {
        let percent = min(Int((fraction * 100).rounded()), fraction < 1.0 ? 99 : 100)
        return "\(max(0, percent))% copied"
    }

    /// The share as its own element so AX probes can read the verdict per row
    /// (`source.clip.<index>.share`, 0-based like the role badge — issue #5/#15).
    private func shareBadge(_ text: String) -> some View {
        Text("· \(text)")
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("source.clip.\(position - 1).share")
            .accessibilityLabel("Copied share")
            .accessibilityValue(Text(text))
    }

    /// The selection's start as approximate media seconds (in point ÷ frame
    /// rate) — where the thumbnail is taken. Nil (near-start default) when
    /// there's no in point or the clip's properties aren't probed yet. An input
    /// seek is keyframe-accurate at best, so frame-exactness isn't attempted.
    private var selectionStartSeconds: Double? {
        guard let inPoint = clip.inPoint, inPoint > 0,
              let raw = clip.video?.frameRate,
              let fps = Self.fps(raw), fps > 0 else { return nil }
        return Double(inPoint) / fps
    }

    // MARK: - Formatting

    // Frame-rate and duration formatting live in the shared `MediaFormatting` so the row
    // and the clip inspector (issue #88) can't drift on how a rate or duration reads.
    private nonisolated static func fps(_ raw: String) -> Double? {
        MediaFormatting.fps(raw)
    }

    private nonisolated static func formattedFrameRate(_ raw: String) -> String {
        MediaFormatting.frameRate(raw)
    }

    private func formattedDuration(_ seconds: Double) -> String {
        MediaFormatting.duration(seconds)
    }
}

/// The row's 44×32 thumbnail box: a frame from the start of the clip's
/// selection once extracted (issue #23), the generic film glyph while loading
/// or when the source is unreachable.
private struct ClipThumbnailView: View {
    let url: URL?
    /// Approximate media time to thumbnail; nil means near the file's start.
    let seconds: Double?
    @State private var image: NSImage?

    /// Re-fires the loading task when either the source or the selection moves.
    private struct Key: Equatable {
        let url: URL?
        let seconds: Double?
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "film")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 32)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        .task(id: Key(url: url, seconds: seconds)) {
            guard let url else {
                image = nil
                return
            }
            if let data = await ClipThumbnailer.shared.pngData(for: url, atSeconds: seconds) {
                image = NSImage(data: data)
            }
        }
    }
}
