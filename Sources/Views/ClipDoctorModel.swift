import SwiftUI
import AppKit

@MainActor
final class ClipDoctorModel: ObservableObject {
    enum DestinationIssue: Equatable {
        case isSource
        case unwritableFolder

        var message: String {
            switch self {
            case .isSource:
                return "That’s the source file — choose a different name or folder for the repaired copy."
            case .unwritableFolder:
                return "That folder can’t be written to — choose a location you can write to for the repaired copy."
            }
        }
    }

    enum Phase {
        case configuring
        case running(progress: Double, eta: String?)
        case verifying(result: ClipDoctorEngine.Result, progress: Double)
        case finished(ClipDoctorEngine.Result)
        case failed(String)
    }

    let document: ProjectDocument
    let clipID: Clip.ID

    @Published var destination: URL
    @Published private(set) var destinationExists = false
    @Published private(set) var destinationError: String?
    @Published private(set) var omittedStreamsNotice: String?
    @Published private(set) var phase: Phase = .configuring
    @Published var fieldCodedAcknowledged = false

    private var task: Task<Void, Never>?
    private var repairStartedAt = Date()
    private var etaEstimator = ExportProgress.ETAEstimator()

    init(document: ProjectDocument, clipID: Clip.ID) {
        self.document = document
        self.clipID = clipID
        if let clip = document.project.clips.first(where: { $0.id == clipID }),
           let source = document.url(for: clip) {
            destination = ClipDoctorEngine.repairedSibling(of: source)
        } else {
            destination = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("repaired")
            phase = .failed("Source file not found.")
        }
        refreshDestinationExists()
        revalidateDestination()
    }

    var clip: Clip? { document.project.clips.first { $0.id == clipID } }

    var damageSummary: String? {
        ClipRowView.damageLineText(zones: clip?.damageZones)
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var isVerifying: Bool {
        if case .verifying = phase { return true }
        return false
    }

    var progress: Double {
        if case .running(let p, _) = phase { return p }
        return 0
    }

    var verifyProgress: Double {
        if case .verifying(_, let p) = phase { return p }
        return 0
    }

    var canVerifyNow: Bool {
        if case .finished(let result) = phase { return result.verdict.outcome == .notVerified }
        return false
    }

    var eta: String? {
        if case .running(_, let eta) = phase { return eta }
        return nil
    }

    var isFieldCoded: Bool { clip?.fieldCoded == true }

    var fieldCodedReencodeNotice: String? {
        guard let clip, isFieldCoded else { return nil }
        return ClipDoctorEngine.fieldCodedReencodeNotice(
            clipName: clip.displayName, duration: clip.duration)
    }

    var canRepair: Bool { destinationError == nil && (!isFieldCoded || fieldCodedAcknowledged) }

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

    func setDestination(_ url: URL) {
        destination = url
        refreshDestinationExists()
        revalidateDestination()
    }

    func refreshDestinationExists() {
        destinationExists = FileManager.default.fileExists(atPath: destination.path)
    }

    private func revalidateDestination() {
        guard let clip, let source = document.url(for: clip) else { destinationError = nil; return }
        destinationError = Self.destinationIssue(destination: destination, source: source)?.message
    }

    nonisolated static func destinationIssue(destination: URL, source: URL) -> DestinationIssue? {
        if ExportEngine.denotesSameFile(destination, source) { return .isSource }
        let folder = destination.deletingLastPathComponent()
        if !FileManager.default.isWritableFile(atPath: folder.path) { return .unwritableFolder }
        return nil
    }

    func probeOmittedStreams() async {
        guard let clip, let source = document.url(for: clip) else { return }
        let others = await MediaProbe.nonAVStreams(url: source)
        omittedStreamsNotice = ClipDoctorEngine.omittedStreamsNotice(others)
    }

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
                self.phase = .configuring
                self.refreshDestinationExists()
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func advance(_ p: Double) {
        guard case .running(let shown, _) = phase, p > shown else { return }
        let remaining = etaEstimator.update(
            fraction: p, elapsed: Date().timeIntervalSince(repairStartedAt))
        phase = .running(progress: p, eta: ExportProgress.etaLabel(remaining: remaining, fraction: p))
    }

    func cancel() {
        task?.cancel()
    }

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

    private func advanceVerify(_ f: Double) {
        guard case .verifying(let result, let shown) = phase, f > shown else { return }
        phase = .verifying(result: result, progress: f)
    }

    func useRepaired() {
        guard case .finished(let result) = phase else { return }
        document.relink(ids: [clipID], to: result.output)
    }

    func reveal() {
        guard case .finished(let result) = phase else { return }
        NSWorkspace.shared.activateFileViewerSelecting([result.output])
    }
}
