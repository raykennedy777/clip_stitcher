import SwiftUI
import UniformTypeIdentifiers

/// Per-clip audio stream settings (ADR-0014), reachable from the Source view and the
/// cut-editor: an ordered list of the clip's audio track slots, each re-pointable at
/// another stream of the clip's own file or an external audio file, plus add/remove.
///
/// Opened on a multi-selection (issue #12 — the same-source gate guarantees every
/// clip reads from the same file), the first clip's slots are shown and a write
/// replaces every selected clip's slot list with the displayed one — clips whose
/// lists had diverged converge on it. Monitored-track choices stay per-clip.
struct AudioSettingsView: View {
    @ObservedObject var document: ProjectDocument
    /// The edited clips in timeline order; the first is the one displayed.
    let clipIDs: [Clip.ID]
    @Environment(\.dismiss) private var dismiss
    /// The slot a presented "choose external file" panel is for. Kept separate from
    /// `isBrowsing` — the importer clears its presentation binding *before* calling
    /// the completion, so deriving visibility from this value would wipe it too
    /// early and the completion would never know which slot was being edited.
    @State private var browsingSlot: Int?
    @State private var isBrowsing = false

    private var clip: Clip? {
        document.project.clips.first { $0.id == clipIDs.first }
    }

    private var selectedClips: [Clip] {
        document.project.clips.filter { clipIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let clip {
                Text(clipIDs.count > 1
                     ? "Audio Tracks — \(clip.displayName) (\(clipIDs.count) clips)"
                     : "Audio Tracks — \(clip.displayName)")
                    .font(.headline)
                    .padding()

                if clip.resolvedAudioSelections.isEmpty {
                    ContentUnavailableView(
                        "No Audio Tracks",
                        systemImage: "speaker.slash",
                        description: Text("This clip contributes silence. Add a track to give it audio.")
                    )
                    .frame(minHeight: 120)
                } else {
                    List {
                        ForEach(Array(clip.resolvedAudioSelections.enumerated()), id: \.offset) { slot, trackSlot in
                            trackRow(clip: clip, slot: slot, trackSlot: trackSlot)
                        }
                    }
                    .frame(minHeight: 160)
                }

                HStack {
                    Button {
                        addSlot(clip: clip)
                    } label: {
                        Label("Add Track", systemImage: "plus")
                    }
                    Button("Restore Clip's Own Tracks") {
                        document.setAudioSelections(ids: Set(clipIDs), selections: nil)
                    }
                    .disabled(selectedClips.allSatisfy { $0.audioSelections == nil })
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding()
            }
        }
        .frame(width: 620)
        .fileImporter(
            isPresented: $isBrowsing,
            allowedContentTypes: Self.audioContentTypes
        ) { result in
            defer { browsingSlot = nil }
            guard let slot = browsingSlot, case .success(let url) = result,
                  let template = clipIDs.first else { return }
            Task {
                await document.setExternalAudio(ids: Set(clipIDs), template: template,
                                                slot: slot, url: url)
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func trackRow(clip: Clip, slot: Int, trackSlot: AudioTrackSlot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Track \(slot + 1)")
                    .frame(width: 64, alignment: .leading)
                    .foregroundStyle(.secondary)

                sourcePicker(clip: clip, slot: slot, selection: trackSlot.selection)

                mixPicker(clip: clip, slot: slot, current: trackSlot.mix)

                Spacer()

                Button {
                    removeSlot(clip: clip, slot: slot)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this track")
            }
            if let gap = clip.externalAudioMismatch(slot: slot), abs(gap) >= 1.0 {
                // Pad/trim is automatic; a gap of 1 s or more is worth pointing out (ADR-0014).
                Label(
                    gap < 0
                        ? "Audio is \(Self.gapText(gap)) shorter than the video — silence will fill the rest."
                        : "Audio is \(Self.gapText(gap)) longer than the video — the extra is unused.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.leading, 64)
            }
        }
        .padding(.vertical, 2)
    }

    /// The slot's source menu: any stream of the clip's own file, any audio stream of
    /// the chosen external file (when it has several), or a new external file.
    private func sourcePicker(clip: Clip, slot: Int, selection: AudioTrackSelection) -> some View {
        Menu {
            ForEach(clip.allAudioTracks.indices, id: \.self) { s in
                Button {
                    updateSlot(clip: clip, slot: slot, to: .stream(s))
                } label: {
                    let name = clip.allAudioTracks[s].displayName(trackNumber: s + 1)
                    if case .stream(s) = selection {
                        Label("\(name) — this file", systemImage: "checkmark")
                    } else {
                        Text("\(name) — this file")
                    }
                }
            }
            // A multi-stream external file (e.g. another video) exposes each of its
            // audio streams as a pickable source for this slot.
            if case .external(let bookmark, let name, let current, let tracks?, let duration) = selection,
               tracks.count > 1 {
                Divider()
                ForEach(tracks.indices, id: \.self) { s in
                    Button {
                        updateSlot(clip: clip, slot: slot, to: .external(
                            bookmark: bookmark, name: name, streamIndex: s,
                            tracks: tracks, duration: duration))
                    } label: {
                        let streamName = tracks[s].displayName(trackNumber: s + 1)
                        if s == current {
                            Label("\(streamName) — \(name)", systemImage: "checkmark")
                        } else {
                            Text("\(streamName) — \(name)")
                        }
                    }
                }
            }
            Divider()
            Button("Other Audio File…") {
                browsingSlot = slot
                isBrowsing = true
            }
        } label: {
            // A long source name (track + file name) must truncate rather than grow,
            // or it pushes the remove button out of the row.
            Text(sourceLabel(clip: clip, slot: slot, selection: selection))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 320, alignment: .leading)
        .help(sourceLabel(clip: clip, slot: slot, selection: selection))
    }

    /// The slot's channel-mix menu (ADR-0019): how this source's channels are mixed
    /// into its output track — never the track's layout. Options that change nothing
    /// for this source are greyed out (Stereo for a mono/stereo source, everything but
    /// Original for mono or unknown). With several clips selected and diverging mixes
    /// the label reads "Multiple"; picking any option converges them.
    private func mixPicker(clip: Clip, slot: Int, current: ChannelMix) -> some View {
        let tracks = clip.effectiveAudioTracks
        let channels = slot < tracks.count ? tracks[slot]?.channels : nil
        let mixes = Set(selectedClips.map { c -> ChannelMix in
            let slots = c.resolvedAudioSelections
            return slot < slots.count ? slots[slot].mix : .original
        })
        let uniform = mixes.count <= 1
        return Menu {
            ForEach(ChannelMix.allCases, id: \.self) { mix in
                Button {
                    updateMix(clip: clip, slot: slot, to: mix)
                } label: {
                    if uniform && mix == current {
                        Label(mix.displayName, systemImage: "checkmark")
                    } else {
                        Text(mix.displayName)
                    }
                }
                .disabled(mix != .original && mix.isNoOp(sourceChannels: channels))
            }
        } label: {
            Text(uniform ? current.displayName : "Multiple")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 100, alignment: .leading)
        .help("Channel mix — how this source's channels are mixed into the output track")
    }

    private func sourceLabel(clip: Clip, slot: Int, selection: AudioTrackSelection) -> String {
        switch selection {
        case .stream(let s):
            return s < clip.allAudioTracks.count
                ? clip.allAudioTracks[s].displayName(trackNumber: s + 1)
                : "Missing stream \(s + 1)"
        case .external(_, let name, let streamIndex, let tracks, _):
            // Name the picked stream when the file has several.
            if let tracks, tracks.count > 1, streamIndex < tracks.count {
                return "\(tracks[streamIndex].displayName(trackNumber: streamIndex + 1)) — \(name)"
            }
            return name
        }
    }

    // MARK: - Mutations

    private func updateSlot(clip: Clip, slot: Int, to selection: AudioTrackSelection) {
        var selections = clip.resolvedAudioSelections
        guard slot < selections.count else { return }
        // A changed source resets the slot's mix to Original — the mix is a judgment
        // about the previous source's content (ADR-0019). Re-picking the same source
        // keeps it.
        if selections[slot].selection != selection {
            selections[slot] = AudioTrackSlot(selection: selection)
        }
        document.setAudioSelections(ids: Set(clipIDs), selections: selections)
    }

    /// Changes only the slot's mix; the source stays put.
    private func updateMix(clip: Clip, slot: Int, to mix: ChannelMix) {
        var selections = clip.resolvedAudioSelections
        guard slot < selections.count else { return }
        selections[slot].mix = mix
        document.setAudioSelections(ids: Set(clipIDs), selections: selections)
    }

    /// A new slot starts on the clip's own next unused stream, wrapping to the first.
    private func addSlot(clip: Clip) {
        var selections = clip.resolvedAudioSelections
        let streamCount = clip.allAudioTracks.count
        let next = streamCount > 0 ? min(selections.count, streamCount - 1) : 0
        selections.append(.stream(next))
        document.setAudioSelections(ids: Set(clipIDs), selections: selections)
    }

    private func removeSlot(clip: Clip, slot: Int) {
        var selections = clip.resolvedAudioSelections
        guard slot < selections.count else { return }
        selections.remove(at: slot)
        document.setAudioSelections(ids: Set(clipIDs), selections: selections)
    }

    private static func gapText(_ gap: Double) -> String {
        String(format: "%.1f s", abs(gap))
    }

    /// External audio file types: pure audio plus the containers we import anyway
    /// (an MKV/MP4 can serve as an audio source via its first audio stream).
    static let audioContentTypes: [UTType] = {
        var types: [UTType] = [.audio, .mp3, .wav, .aiff, .mpeg4Audio]
        for ext in ["ac3", "mp2", "m4a", "aac", "flac", "mka"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types + SourceView.contentTypes
    }()
}
