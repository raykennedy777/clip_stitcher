import SwiftUI

/// The trailing inspector's read-only technical read-out of the selected clip (issue #88):
/// container/duration/size, the full video and audio spec, and — the point of it — a Match
/// section naming every strict-compare property that differs from the target clip. The
/// mismatch list is driven entirely by `MatchEvaluator.differences`, so it can never disagree
/// with the row's smart-render / re-encode verdict.
///
/// Read-only for 1.0 — no editing controls. Adds no probing: every value comes from data
/// already on the `Clip` (plus the source file's on-disk size, a plain filesystem stat).
struct ClipInspectorView: View {
    @ObservedObject var document: ProjectDocument
    /// The Source list's live selection — the inspector re-renders as it moves (arrow keys
    /// included), showing the single selected clip or an N-selected / no-selection placeholder.
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

    /// The one selected clip, or nil when zero or many are selected.
    private var singleSelectedClip: Clip? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return document.project.clips.first { $0.id == id }
    }

    // MARK: - Placeholder (multi / empty selection)

    /// HIG "No Selection" convention: an empty selection reads "No Clip Selected"; a
    /// multi-selection reads "N Clips Selected" — the inspector describes exactly one clip,
    /// so it steps aside rather than trying to merge readings.
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

    // MARK: - Clip detail

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

    // MARK: - File / container

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

    /// The source's container, from its file extension (uppercased) — a fact of the source
    /// file, not a media probe.
    private func container(for clip: Clip) -> String? {
        let ext = (document.url(for: clip)?.pathExtension ?? (clip.displayName as NSString).pathExtension)
        return ext.isEmpty ? nil : ext.uppercased()
    }

    /// The source file's on-disk size, read from the resolved URL; nil when unresolved.
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

    /// The damage read-out: zone count, naming a truncated ending where the shared
    /// classification (`ProjectDocument.hasTruncatedEnding`) finds one. nil hides the row
    /// for a clip that predates detection or hasn't been scanned. "None detected" when clean.
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

    // MARK: - Video

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

    /// Codec plus profile/level when known, e.g. "H264 · High @ L4.0".
    private func codecText(_ v: VideoProperties) -> String {
        var text = v.codec.uppercased()
        if let profile = v.profile, !profile.isEmpty {
            text += " · \(profile)"
            if let level = v.level, !level.isEmpty { text += " @ L\(level)" }
        }
        return text
    }

    /// Display aspect ratio with the sample (pixel) aspect noted when the pixels aren't
    /// square, e.g. "16:9 (PAR 64:45)".
    private func aspectText(sar: String?, dar: String) -> String {
        if let sar, !sar.isEmpty, sar != "1:1" { return "\(dar) (PAR \(sar))" }
        return dar
    }

    /// Scan type, appending the field-coded (PAFF) gloss (CONTEXT.md) when the source stores
    /// two field pictures per frame — the app's frame numbering runs at 2× there.
    private func scanTypeText(_ clip: Clip, _ v: VideoProperties) -> String {
        let base = MediaFormatting.scanType(v.fieldOrder)
        return clip.fieldCoded == true ? "\(base) · field-coded (two half-pictures per frame)" : base
    }

    /// The color triple + range as a compact line, omitted entirely when the stream carries
    /// no color tags at all (a common untagged SD source).
    private func colorText(_ v: VideoProperties) -> String? {
        let parts = [v.colorPrimaries, v.colorTransfer, v.colorSpace, v.colorRange]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Audio

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

    /// One audio track's spec, e.g. "AAC · 48 kHz · stereo"; "—" when the feeding stream's
    /// properties are unknown (an unprobed external file).
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

    // MARK: - Match (why it doesn't match)

    @ViewBuilder
    private func matchSection(_ clip: Clip) -> some View {
        Section("Match") {
            if let target = document.project.targetClip, target.id == clip.id {
                verdictRow("This is the target clip.", systemImage: "target", tint: .accentColor)
            } else if document.project.targetClip == nil {
                verdictRow("No target clip set.", systemImage: "questionmark.circle", tint: .secondary)
            } else if clip.video == nil {
                verdictRow("No video track to compare.", systemImage: "exclamationmark.triangle", tint: .orange)
            } else {
                matchBody(clip, target: document.project.targetClip!)
            }
        }
    }

    @ViewBuilder
    private func matchBody(_ clip: Clip, target: Clip) -> some View {
        let diffs = MatchEvaluator.differences(clip, target: target)
        if diffs.isEmpty {
            verdictRow("Matches the target — will smart render.", systemImage: "bolt", tint: .green)
        } else {
            verdictRow(
                diffs.count == 1 ? "1 difference from the target — will re-encode."
                                 : "\(diffs.count) differences from the target — will re-encode.",
                systemImage: "arrow.triangle.2.circlepath", tint: .orange)
            ForEach(Array(diffs.enumerated()), id: \.offset) { index, diff in
                differenceRow(diff, index: index)
            }
        }
    }

    /// One mismatch, named with both values ("Frame rate 25 → 29.997"). The clip's value and
    /// the target's are shown side by side; the whole line is exposed to AX as one value so a
    /// probe can assert the exact difference.
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

    // MARK: - Row helper

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
