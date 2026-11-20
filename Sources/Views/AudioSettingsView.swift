import SwiftUI
import UniformTypeIdentifiers

struct AudioSettingsView: View {
    @ObservedObject var document: ProjectDocument
    let clipIDs: [Clip.ID]
    @Environment(\.dismiss) private var dismiss
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
            // ADR-0037
            defer { browsingSlot = nil }
            guard let slot = browsingSlot, case .success(let url) = result,
                  let template = clipIDs.first else { return }
            Task {
                await document.setExternalAudio(ids: Set(clipIDs), template: template,
                                                slot: slot, url: url)
            }
        }
    }

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
            Text(sourceLabel(clip: clip, slot: slot, selection: selection))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 320, alignment: .leading)
        .help(sourceLabel(clip: clip, slot: slot, selection: selection))
    }

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
            if let tracks, tracks.count > 1, streamIndex < tracks.count {
                return "\(tracks[streamIndex].displayName(trackNumber: streamIndex + 1)) — \(name)"
            }
            return name
        }
    }

    private func updateSlot(clip: Clip, slot: Int, to selection: AudioTrackSelection) {
        var selections = clip.resolvedAudioSelections
        guard slot < selections.count else { return }
        if selections[slot].selection != selection {
            selections[slot] = AudioTrackSlot(selection: selection)
        }
        document.setAudioSelections(ids: Set(clipIDs), selections: selections)
    }

    private func updateMix(clip: Clip, slot: Int, to mix: ChannelMix) {
        var selections = clip.resolvedAudioSelections
        guard slot < selections.count else { return }
        selections[slot].mix = mix
        document.setAudioSelections(ids: Set(clipIDs), selections: selections)
    }

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

    static let audioContentTypes: [UTType] = {
        var types: [UTType] = [.audio, .mp3, .wav, .aiff, .mpeg4Audio]
        for ext in ["ac3", "mp2", "m4a", "aac", "flac", "mka"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types + SourceView.contentTypes
    }()
}
