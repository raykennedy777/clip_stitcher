import SwiftUI
import AppKit

enum ClipRole {
    case target
    case smartRender
    case reEncode
    case cutOnly
    case unknown

    nonisolated static func role(for clip: Clip, target: Clip?, output: OutputSettings) -> ClipRole {
        if clip.id == target?.id { return .target }
        if output.mode == .separate && output.rendering == .cutOnly { return .cutOnly }
        guard let target, clip.video != nil else { return .unknown }
        return MatchEvaluator.matches(clip, target: target) ? .smartRender : .reEncode
    }

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
    let url: URL?
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
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("source.clip.\(position - 1).role")
            .accessibilityLabel("Role")
            .accessibilityValue(Text(text))
    }

    nonisolated static func detailLine(for clip: Clip) -> String {
        guard let v = clip.video else { return "Reading…" }
        var parts: [String] = ["\(v.codec.uppercased()) \(v.width)×\(v.height)"]
        if !v.frameRate.isEmpty, v.frameRate != "0/0" {
            parts.append("\(formattedFrameRate(v.frameRate)) fps")
        }
        if let order = v.fieldOrder {
            parts.append(MediaFormatting.isProgressive(order) ? "progressive" : "interlaced (\(order))")
        }
        let tracks = clip.effectiveAudioTracks
        if let a = tracks.first ?? nil {
            parts.append("\(a.codec.uppercased()) \(a.channels)ch \(a.sampleRate / 1000)kHz")
            if tracks.count > 1 {
                parts.append("\(tracks.count) audio tracks")
            }
        } else if !tracks.isEmpty {
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

    nonisolated static func damageLineText(zones: [DamageZone]?) -> String? {
        guard let zones, !zones.isEmpty else { return nil }
        let shown = zones.prefix(6).map { ExportPlanner.formattedClipTime($0.start) }
        let times = shown.joined(separator: ", ") + (zones.count > 6 ? ", …" : "")
        return zones.count == 1
            ? "Damage zone at \(times)"
            : "\(zones.count) damage zones at \(times)"
    }

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

    private var shareText: String? {
        share.map { Self.copiedShareText(fraction: $0.copiedFraction) }
    }

    // ADR-0037
    nonisolated static func copiedShareText(fraction: Double) -> String {
        let percent = min(Int((fraction * 100).rounded()), fraction < 1.0 ? 99 : 100)
        return "\(max(0, percent))% copied"
    }

    private func shareBadge(_ text: String) -> some View {
        Text("· \(text)")
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("source.clip.\(position - 1).share")
            .accessibilityLabel("Copied share")
            .accessibilityValue(Text(text))
    }

    private var selectionStartSeconds: Double? {
        guard let inPoint = clip.inPoint, inPoint > 0,
              let raw = clip.video?.frameRate,
              let fps = Self.fps(raw), fps > 0 else { return nil }
        return Double(inPoint) / fps
    }

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

private struct ClipThumbnailView: View {
    let url: URL?
    let seconds: Double?
    @State private var image: NSImage?

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
