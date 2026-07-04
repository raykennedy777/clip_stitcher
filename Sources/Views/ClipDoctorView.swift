import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Clip Doctor sheet (issue #53, ADR-0021): confirm a repair-only export of one
/// damaged clip, watch it run, then read the **verdict** — the headline is whether the
/// repaired copy re-scanned clean, not merely that the recipe ran. Reachable from the
/// Source action panel and the import banner (#55). Same sheet pattern as Audio Settings
/// / Relink; the work itself lives in `ClipDoctorModel` + `ClipDoctorEngine`.
struct ClipDoctorView: View {
    @StateObject private var model: ClipDoctorModel
    @Environment(\.dismiss) private var dismiss

    init(document: ProjectDocument, clipID: Clip.ID) {
        _model = StateObject(wrappedValue: ClipDoctorModel(document: document, clipID: clipID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Group {
                switch model.phase {
                case .finished, .verifying:
                    outcome
                default:
                    configuration
                }
            }
            .padding()
            Divider()
            footer
        }
        .frame(width: 560)
        .accessibilityIdentifier("clipDoctor.sheet")
        .task { await model.probeOmittedStreams() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Clip Doctor — \(model.clip?.displayName ?? "")")
                .font(.headline)
            if let damage = model.damageSummary {
                Label(damage, systemImage: "bandage")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    // MARK: - Configuration / progress

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Field-coded (PAFF) sources are re-encoded in full (issue #54): say so up
            // front, with a time estimate, and require an explicit opt-in before Repair.
            if let notice = model.fieldCodedReencodeNotice {
                VStack(alignment: .leading, spacing: 8) {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("clipDoctor.reencodeNotice")
                        .accessibilityValue(Text(notice))
                    Toggle("Re-encode the whole clip and continue", isOn: $model.fieldCodedAcknowledged)
                        .disabled(model.isRunning)
                        .accessibilityIdentifier("clipDoctor.reencodeOptIn")
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Repaired copy")
                    .font(.subheadline.weight(.semibold))
                HStack {
                    Text(model.destination.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .help(model.destination.path)
                        .accessibilityIdentifier("clipDoctor.destination")
                        .accessibilityValue(Text(model.destination.path))
                    Spacer()
                    Button("Change…") { changeDestination() }
                        .disabled(model.isRunning)
                        .accessibilityIdentifier("clipDoctor.change")
                }
                if let destError = model.destinationError {
                    // Validated on pick (issue #83): a source collision or an unwritable
                    // folder is caught here and disables Repair, rather than failing after
                    // the click. Takes precedence over the overwrite notice.
                    Label(destError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("clipDoctor.destinationError")
                        .accessibilityValue(Text(destError))
                } else if model.destinationExists {
                    // Explicit, never silent (ADR-0021): the action button below reads
                    // "Replace" and the user opts in; the source is never the target.
                    Label("A repaired copy already exists here — Repair will replace it.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            // Video + audio only (ADR-0021): name what won't be carried, never silent.
            if let notice = model.omittedStreamsNotice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("clipDoctor.omitted")
            }

            if model.isRunning {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: model.progress)
                        .accessibilityIdentifier("clipDoctor.progress")
                    HStack {
                        Text(model.progress, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                        if let eta = model.eta {
                            Text("·")
                            Text(eta)
                                .accessibilityIdentifier("clipDoctor.eta")
                                .accessibilityValue(Text(eta))
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("clipDoctor.status")
                    .accessibilityValue(Text(error))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Outcome (verdict is the headline)

    @ViewBuilder
    private var outcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isVerifying {
                // Re-verify in flight (issue #82): show the scan's progress in place of the
                // stale not-verified verdict; the footer offers Cancel.
                VStack(alignment: .leading, spacing: 6) {
                    Label("Verifying the repaired file…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    ProgressView(value: model.verifyProgress)
                        .accessibilityIdentifier("clipDoctor.verifyProgress")
                }
                .fixedSize(horizontal: false, vertical: true)
            } else if let verdict = model.result?.verdict {
                Label {
                    Text(verdict.message)
                } icon: {
                    Image(systemName: verdictIcon(verdict.outcome))
                }
                .font(.headline)
                .foregroundStyle(verdictColor(verdict.outcome))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("clipDoctor.verdict")
                .accessibilityValue(Text(verdict.message))

                if let report = supportingReport {
                    Text(report)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let output = model.result?.output {
                Label(output.path, systemImage: "doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(output.path)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The supporting report under the verdict — the shared "Repaired N damage zones at …"
    /// wording (ExportPlanner), so the sheet, the row, and the export report can't drift.
    /// Whole-file, so no kept window bounds the count. The "and a truncated ending" naming reads
    /// the engine's own truncated-ending decision off the result (`truncatedEndingTrim`), so it
    /// survives a nil probed `duration` — the classification comes off the frame index, not the
    /// container duration (issue #79).
    private var supportingReport: String? {
        guard let clip = model.clip else { return nil }
        return ExportPlanner.repairReport(
            clipName: clip.displayName, zones: clip.damageZones,
            windowStart: nil, windowEnd: clip.duration,
            trimEnd: model.result?.truncatedEndingTrim,
            frameInterval: ExportPlanner.frameDuration(clip.video?.frameRate))
    }

    private func verdictIcon(_ outcome: ClipDoctorEngine.Verdict.Outcome) -> String {
        switch outcome {
        case .clean: return "checkmark.seal.fill"
        case .zonesRemain: return "exclamationmark.triangle.fill"
        case .inconclusive: return "questionmark.circle.fill"
        case .notVerified: return "pause.circle.fill"
        }
    }

    private func verdictColor(_ outcome: ClipDoctorEngine.Verdict.Outcome) -> Color {
        switch outcome {
        case .clean: return .green
        case .zonesRemain, .inconclusive, .notVerified: return .orange
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            switch model.phase {
            case .configuring, .failed:
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(model.destinationExists ? "Replace" : "Repair") { model.repair() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canRepair)
                    .accessibilityIdentifier("clipDoctor.repair")
            case .running, .verifying:
                Spacer()
                Button("Cancel") { model.cancel() }
                    .accessibilityIdentifier("clipDoctor.cancel")
            case .finished:
                Button("Reveal in Finder") { model.reveal() }
                    .accessibilityIdentifier("clipDoctor.reveal")
                Spacer()
                // A cancelled verify (issue #82) left the file unchecked — offer to re-run
                // verification on the kept file rather than only reporting the cancel.
                if model.canVerifyNow {
                    Button("Verify Now") { model.verifyNow() }
                        .accessibilityIdentifier("clipDoctor.verifyNow")
                }
                Button("Use Repaired File in This Project") {
                    model.useRepaired()
                    dismiss()
                }
                .accessibilityIdentifier("clipDoctor.useRepaired")
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("clipDoctor.done")
            }
        }
        .padding()
    }

    // MARK: - Destination panel

    /// Lets the user move the repaired copy elsewhere. The source's extension is kept —
    /// same container in, same container out (ADR-0021) — so it's re-appended if dropped.
    private func changeDestination() {
        let ext = model.destination.pathExtension
        let panel = NSSavePanel()
        panel.title = "Repaired Copy"
        panel.prompt = "Choose"
        panel.canCreateDirectories = true
        panel.showsTagField = false
        panel.nameFieldStringValue = model.destination.lastPathComponent
        panel.directoryURL = model.destination.deletingLastPathComponent()
        if let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension.lowercased() != ext.lowercased() { url.appendPathExtension(ext) }
        model.setDestination(url)
    }
}
