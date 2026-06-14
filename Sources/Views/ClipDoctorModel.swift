import SwiftUI
import AppKit

/// Drives one Clip Doctor repair sheet (issue #53, ADR-0021): the chosen destination and
/// its overwrite guard, the non-AV-stream notice, and the engine run — progress,
/// cancellation, and the verdict. Owned by the sheet as a `@StateObject`; the document
/// supplies the import-time caches (`doctorInputs`) and the relink path.
@MainActor
final class ClipDoctorModel: ObservableObject {
    enum Phase {
        case configuring
        case running(progress: Double)
        case finished(ClipDoctorEngine.Result)
        case failed(String)
    }

    let document: ProjectDocument
    let clipID: Clip.ID

    /// The repaired-output destination. Defaults to the `_repaired` sibling; the
    /// Change… panel can move it (same container in/out, ADR-0021).
    @Published var destination: URL
    /// Whether `destination` already exists — the overwrite guard. A run replaces it
    /// only on an explicit Replace, never silently (ADR-0021).
    @Published private(set) var destinationExists = false
    /// The subtitle/teletext/data streams the repair won't carry, as a notice — nil
    /// when the source has none (probed lazily when the sheet appears).
    @Published private(set) var omittedStreamsNotice: String?
    @Published private(set) var phase: Phase = .configuring

    private var task: Task<Void, Never>?

    init(document: ProjectDocument, clipID: Clip.ID) {
        self.document = document
        self.clipID = clipID
        if let clip = document.project.clips.first(where: { $0.id == clipID }),
           let source = document.url(for: clip) {
            destination = ClipDoctorEngine.repairedSibling(of: source)
        } else {
            // The button gates on a resolvable source, so this is defensive only — show
            // the failure rather than a bogus path.
            destination = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("repaired")
            phase = .failed("Source file not found.")
        }
        refreshDestinationExists()
    }

    var clip: Clip? { document.project.clips.first { $0.id == clipID } }

    /// The header's damage-zone line — the same wording as the source row (issue #45),
    /// so the row badge, this sheet, and the export report all agree.
    var damageSummary: String? {
        ClipRowView.damageLineText(zones: clip?.damageZones)
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var progress: Double {
        if case .running(let p) = phase { return p }
        return 0
    }

    var result: ClipDoctorEngine.Result? {
        if case .finished(let r) = phase { return r }
        return nil
    }

    var errorMessage: String? {
        if case .failed(let m) = phase { return m }
        return nil
    }

    // MARK: - Destination

    func setDestination(_ url: URL) {
        destination = url
        refreshDestinationExists()
    }

    func refreshDestinationExists() {
        destinationExists = FileManager.default.fileExists(atPath: destination.path)
    }

    /// Probes the source for streams Clip Doctor won't carry (ADR-0021). Called once
    /// when the sheet appears; a probe failure simply leaves no notice.
    func probeOmittedStreams() async {
        guard let clip, let source = document.url(for: clip) else { return }
        let others = await MediaProbe.nonAVStreams(url: source)
        omittedStreamsNotice = ClipDoctorEngine.omittedStreamsNotice(others)
    }

    // MARK: - Run / cancel

    /// Runs the repair to `destination`. Overwrites only when the destination already
    /// exists *and* the user chose Replace (the button enforces this), passing the
    /// engine its own guard; the source is never touched.
    func repair() {
        guard let clip else { phase = .failed("Source file not found."); return }
        let overwrite = destinationExists
        let dest = destination
        phase = .running(progress: 0)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let inputs = try await self.document.doctorInputs(for: clip)
                let result = try await ClipDoctorEngine.repair(
                    source: inputs.url, clip: clip, index: inputs.index,
                    containerStart: inputs.containerStart, destination: dest, overwrite: overwrite
                ) { p in
                    Task { @MainActor [weak self] in self?.advance(p) }
                }
                self.phase = .finished(result)
            } catch is CancellationError {
                // The engine left no destination and never touched the source — back to
                // the start so the user can retry (issue #53).
                self.phase = .configuring
                self.refreshDestinationExists()
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Keeps the progress bar monotonic — progress arrives from a background reader.
    private func advance(_ p: Double) {
        guard case .running(let shown) = phase, p > shown else { return }
        phase = .running(progress: p)
    }

    /// Cancels the running repair — `ProcessRunner` terminates the live ffmpeg, the
    /// engine cleans its temp work, and the phase returns to configuring (issue #53).
    func cancel() {
        task?.cancel()
    }

    // MARK: - Outcome actions

    /// Relinks the project clip to the repaired file (issue #53), reusing the relink
    /// path so it re-imports and re-runs detection — the doctored file becomes the
    /// clip's source. The source on disk is unchanged; only the project points anew.
    func useRepaired() {
        guard case .finished(let result) = phase else { return }
        document.relink(ids: [clipID], to: result.output)
    }

    /// Shows the repaired file in the Finder.
    func reveal() {
        guard case .finished(let result) = phase else { return }
        NSWorkspace.shared.activateFileViewerSelecting([result.output])
    }
}
