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
        case running(progress: Double, eta: String?)
        /// Re-verifying an already-finished output after a cancelled verify (issue #82):
        /// the finished result is carried through so the file path and prior verdict stay
        /// on screen while the re-scan runs; on completion it swaps to `.finished` with the
        /// fresh verdict.
        case verifying(result: ClipDoctorEngine.Result, progress: Double)
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
    /// A field-coded (PAFF) source is re-encoded in full (issue #54) — slower and not
    /// bit-identical — so the sheet requires an explicit opt-in before Repair runs, set
    /// by the configuration toggle. Always false (and unused) for a progressive source.
    @Published var fieldCodedAcknowledged = false

    private var task: Task<Void, Never>?
    /// Wall-clock start of the running repair and its damped estimator, for the
    /// time-remaining label (issue #54) — the same infra the main export uses.
    private var repairStartedAt = Date()
    private var etaEstimator = ExportProgress.ETAEstimator()

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

    /// Whether a Verify Now re-scan is in flight (issue #82) — drives the outcome view's
    /// re-verify progress bar in place of the verdict.
    var isVerifying: Bool {
        if case .verifying = phase { return true }
        return false
    }

    var progress: Double {
        if case .running(let p, _) = phase { return p }
        return 0
    }

    /// The re-verify scan's 0…1 fraction (issue #82); 0 unless a Verify Now is running.
    var verifyProgress: Double {
        if case .verifying(_, let p) = phase { return p }
        return 0
    }

    /// Whether the finished verdict is a cancelled verification (issue #82) — the trigger
    /// for the Verify Now affordance in the finished footer. False for a normal verdict.
    var canVerifyNow: Bool {
        if case .finished(let result) = phase { return result.verdict.outcome == .notVerified }
        return false
    }

    /// The damped "About X remaining" label while running — nil until there's enough
    /// signal, or when not running (issue #54).
    var eta: String? {
        if case .running(_, let eta) = phase { return eta }
        return nil
    }

    /// Whether the source needs the field-coded re-encode (issue #54): damage-to-EOF,
    /// not smart render. Drives the up-front notice and the explicit opt-in.
    var isFieldCoded: Bool { clip?.fieldCoded == true }

    /// The up-front field-coded re-encode notice (issue #54), nil for a progressive
    /// source. Shown before Repair runs; the user must also acknowledge it.
    var fieldCodedReencodeNotice: String? {
        guard let clip, isFieldCoded else { return nil }
        return ClipDoctorEngine.fieldCodedReencodeNotice(
            clipName: clip.displayName, duration: clip.duration)
    }

    /// Whether Repair may start: always true for a progressive source; a field-coded
    /// source needs the explicit opt-in first (issue #54).
    var canRepair: Bool { !isFieldCoded || fieldCodedAcknowledged }

    var result: ClipDoctorEngine.Result? {
        switch phase {
        case .finished(let r), .verifying(let r, _): return r
        default: return nil
        }
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
        repairStartedAt = Date()
        etaEstimator = ExportProgress.ETAEstimator()
        phase = .running(progress: 0, eta: nil)
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

    /// Keeps the progress bar monotonic — progress arrives from a background reader —
    /// and refreshes the damped time-remaining label (issue #54), mirroring the main
    /// export's ETA path.
    private func advance(_ p: Double) {
        guard case .running(let shown, _) = phase, p > shown else { return }
        let remaining = etaEstimator.update(
            fraction: p, elapsed: Date().timeIntervalSince(repairStartedAt))
        phase = .running(progress: p, eta: ExportProgress.etaLabel(remaining: remaining, fraction: p))
    }

    /// Cancels the running repair or re-verify — `ProcessRunner` terminates the live
    /// ffmpeg/ffprobe at once, so the scan stops immediately, not just its result discarded.
    /// A cancel *before* the repaired file lands returns to configuring with nothing on disk
    /// (issue #53); a cancel *during* the verify pass — the file already written — lands on
    /// finished with a "not verified" verdict, the file kept (issue #82); a cancel during a
    /// Verify Now re-scan leaves the not-verified verdict in place.
    func cancel() {
        task?.cancel()
    }

    // MARK: - Outcome actions

    /// Re-runs verification on the repaired output after a cancelled verify (issue #82):
    /// the same scan + detection the auto-verify runs, on the file already on disk — no new
    /// machinery beyond re-invoking `verifyOutput` on the destination. Only from the finished
    /// state; the fresh verdict replaces the old one in place. Cancellable (`cancel()` stops
    /// the scan and lands back on `.finished` with the not-verified verdict — the output is
    /// untouched either way).
    func verifyNow() {
        guard case .finished(let result) = phase, let clip else { return }
        let output = result.output
        let clipName = clip.displayName
        let expectedDuration = clip.duration
        phase = .verifying(result: result, progress: 0)
        task = Task { [weak self] in
            guard let self else { return }
            let verdict = await ClipDoctorEngine.verifyOutput(
                output, clipName: clipName, expectedDuration: expectedDuration
            ) { f in
                Task { @MainActor [weak self] in self?.advanceVerify(f) }
            }
            var updated = result
            updated.verdict = verdict
            self.phase = .finished(updated)
        }
    }

    /// Keeps the re-verify progress bar monotonic — progress arrives from a background
    /// reader (issue #82), mirroring `advance` for the repair run.
    private func advanceVerify(_ f: Double) {
        guard case .verifying(let result, let shown) = phase, f > shown else { return }
        phase = .verifying(result: result, progress: f)
    }

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
