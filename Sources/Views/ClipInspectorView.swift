import SwiftUI

struct ClipInspectorView: View {
    @ObservedObject var document: ProjectDocument
    let selection: Set<Clip.ID>

    var body: some View {
        Group {
            if let clip = singleSelectedClip {
                clipDetail(clip)
            } else {
                placeholder
            }
        }
        .frame(minWidth: 260, idealWidth: 300)
    }

    private var singleSelectedClip: Clip? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return document.project.clips.first { $0.id == id }
    }

    private var placeholder: some View {
        let title = selection.isEmpty ? "No Clip Selected" : "\(selection.count) Clips Selected"
        return VStack(spacing: 8) {
            Image(systemName: selection.isEmpty ? "sidebar.right" : "film.stack")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("inspector.placeholder")
        .accessibilityValue(Text(title))
    }

    @ViewBuilder
    private func clipDetail(_ clip: Clip) -> some View {
        Form {
            fileSection(clip)
            if let video = clip.video {
                videoSection(clip, video)
            }
            audioSection(clip)
            matchSection(clip)
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func fileSection(_ clip: Clip) -> some View {
        Section("File") {
            row("Name", clip.displayName, id: "inspector.name")
            if let container = container(for: clip) {
                row("Container", container, id: "inspector.container")
            }
            if let duration = clip.duration {
                row("Duration", MediaFormatting.duration(duration), id: "inspector.duration")
            }
            if let size = fileSize(for: clip) {
                row("Size", size, id: "inspector.fileSize")
            }
            row("Import", importStateText(clip), id: "inspector.importState")
            if let damage = damageText(clip) {
                row("Damage", damage, id: "inspector.damage")
            }
        }
    }

    private func container(for clip: Clip) -> String? {
        let ext = (document.url(for: clip)?.pathExtension ?? (clip.displayName as NSString).pathExtension)
        return ext.isEmpty ? nil : ext.uppercased()
    }

    private func fileSize(for clip: Clip) -> String? {
        guard let url = document.url(for: clip),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return MediaFormatting.fileSize(Int64(size))
    }

    private func importStateText(_ clip: Clip) -> String {
        switch document.importStates[clip.id] ?? .ready {
        case .probing: return "Reading properties…"
        case .indexing: return "Indexing frames…"
        case .ready: return "Ready"
        case .sourceMissing: return "Source missing"
        case .failed(let message): return message
        }
    }

    private func damageText(_ clip: Clip) -> String? {
        guard let zones = clip.damageZones else { return nil }
        if zones.isEmpty { return "None detected" }
        let truncated = document.hasTruncatedEnding(clip)
        let count = zones.count
        if truncated {
            return count == 1 ? "A truncated ending"
                              : "\(count) damage zones (one a truncated ending)"
        }
        return count == 1 ? "1 damage zone" : "\(count) damage zones"
    }

    @ViewBuilder
    private func videoSection(_ clip: Clip, _ video: VideoProperties) -> some View {
        Section("Video") {
            row("Codec", codecText(video), id: "inspector.video.codec")
            row("Dimensions", "\(video.width)×\(video.height)", id: "inspector.video.dimensions")
            if let dar = MediaFormatting.displayAspectRatio(
                width: video.width, height: video.height, sar: video.sampleAspectRatio) {
                row("Aspect ratio", aspectText(sar: video.sampleAspectRatio, dar: dar),
                    id: "inspector.video.aspect")
            }
            if !video.frameRate.isEmpty, video.frameRate != "0/0" {
                row("Frame rate", "\(MediaFormatting.frameRate(video.frameRate)) fps",
                    id: "inspector.video.frameRate")
            }
            row("Scan type", scanTypeText(clip, video), id: "inspector.video.scan")
            if let color = colorText(video) {
                row("Color", color, id: "inspector.video.color")
            }
        }
    }

    private func codecText(_ v: VideoProperties) -> String {
        var text = v.codec.uppercased()
        if let profile = v.profile, !profile.isEmpty {
            text += " · \(profile)"
            if let level = v.level, !level.isEmpty { text += " @ L\(level)" }
        }
        return text
    }

    private func aspectText(sar: String?, dar: String) -> String {
        if let sar, !sar.isEmpty, sar != "1:1" { return "\(dar) (PAR \(sar))" }
        return dar
    }

    private func scanTypeText(_ clip: Clip, _ v: VideoProperties) -> String {
        let base = MediaFormatting.scanType(v.fieldOrder)
        return clip.fieldCoded == true ? "\(base) · field-coded (two half-pictures per frame)" : base
    }

    private func colorText(_ v: VideoProperties) -> String? {
        let parts = [v.colorPrimaries, v.colorTransfer, v.colorSpace, v.colorRange]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func audioSection(_ clip: Clip) -> some View {
        let tracks = clip.effectiveAudioTracks
        if !tracks.isEmpty {
            Section("Audio") {
                ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                    row(clip.audioTrackName(index), audioText(track), id: "inspector.audio.\(index)")
                }
            }
        }
    }

    private func audioText(_ track: AudioProperties?) -> String {
        guard let track else { return "—" }
        var parts = ["\(track.codec.uppercased())", "\(track.sampleRate / 1000) kHz"]
        if let layout = track.channelLayout, !layout.isEmpty {
            parts.append(layout)
        } else {
            parts.append(track.channels == 1 ? "mono" : "\(track.channels)ch")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func matchSection(_ clip: Clip) -> some View {
        Section("Match") {
            switch MatchEvaluator.matchVerdict(for: clip, target: document.project.targetClip) {
            case .isTarget:
                verdictRow("This is the target clip.", systemImage: "target", tint: .accentColor)
            case .noTarget:
                verdictRow("No target clip set.", systemImage: "questionmark.circle", tint: .secondary)
            case .clipHasNoVideo:
                verdictRow("No video track to compare.", systemImage: "exclamationmark.triangle", tint: .orange)
            case .targetHasNoVideo:
                verdictRow("The target has no video track to compare — will re-encode.",
                           systemImage: "arrow.triangle.2.circlepath", tint: .orange)
            case .smartRender:
                verdictRow("Matches the target — will smart render.", systemImage: "bolt", tint: .green)
            case .reEncode(let diffs):
                reEncodeRows(diffs)
            }
        }
    }

    @ViewBuilder
    private func reEncodeRows(_ diffs: [MatchEvaluator.VideoDifference]) -> some View {
        verdictRow(
            diffs.count == 1 ? "1 difference from the target — will re-encode."
                             : "\(diffs.count) differences from the target — will re-encode.",
            systemImage: "arrow.triangle.2.circlepath", tint: .orange)
        ForEach(Array(diffs.enumerated()), id: \.offset) { index, diff in
            differenceRow(diff, index: index)
        }
    }

    private func differenceRow(_ diff: MatchEvaluator.VideoDifference, index: Int) -> some View {
        let value = "\(diff.clipValue) → \(diff.targetValue)"
        return VStack(alignment: .leading, spacing: 2) {
            Text(diff.label).font(.callout.weight(.medium))
            HStack(spacing: 4) {
                Text(diff.clipValue).foregroundStyle(.primary)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                Text(diff.targetValue).foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("inspector.match.diff.\(index)")
        .accessibilityLabel(Text(diff.label))
        .accessibilityValue(Text(value))
    }

    private func verdictRow(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .foregroundStyle(tint)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("inspector.match.verdict")
            .accessibilityValue(Text(text))
    }

    private func row(_ label: String, _ value: String, id: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
        .accessibilityValue(Text(value))
    }
}
