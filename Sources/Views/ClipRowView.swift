import SwiftUI

enum ClipRole {
    case target
    case smartRender
    case reEncode
    case unknown
}

struct ClipRowView: View {
    let position: Int
    let clip: Clip
    let role: ClipRole
    let state: ImportState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(position)")
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)

            Image(systemName: "film")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 32)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(clip.displayName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    roleBadge
                }
                Text(detailLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                statusLine
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
    }

    // MARK: - Detail / status

    private var detailLine: String {
        guard let v = clip.video else { return "Reading…" }
        var parts: [String] = ["\(v.codec.uppercased()) \(v.width)×\(v.height)"]
        if !v.frameRate.isEmpty, v.frameRate != "0/0" {
            parts.append("\(formattedFrameRate(v.frameRate)) fps")
        }
        if let order = v.fieldOrder {
            parts.append(order == "progressive" ? "progressive" : "interlaced (\(order))")
        }
        if let a = clip.audio {
            parts.append("\(a.codec.uppercased()) \(a.channels)ch \(a.sampleRate / 1000)kHz")
            let trackCount = clip.allAudioTracks.count
            if trackCount > 1 {
                parts.append("\(trackCount) audio tracks")
            }
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
                Text("\(frames) frames · \(formattedDuration(duration))")
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

    /// Shown only when the clip has a selection narrower than the whole clip.
    @ViewBuilder
    private var selectionLine: some View {
        if clip.inPoint != nil || clip.outPoint != nil {
            let inFrame = clip.inPoint ?? 0
            let outFrame = clip.outPoint ?? max(0, (clip.frameCount ?? 1) - 1)
            Label("In \(inFrame) – Out \(outFrame) · \(max(0, outFrame - inFrame + 1)) frames", systemImage: "scissors")
                .font(.caption.weight(.medium))
                .foregroundStyle(.tint)
        }
    }

    // MARK: - Formatting

    private func formattedFrameRate(_ raw: String) -> String {
        let parts = raw.split(separator: "/")
        guard parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]), den != 0 else {
            return raw
        }
        let fps = num / den
        return fps == fps.rounded() ? String(format: "%.0f", fps) : String(format: "%.3f", fps)
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
