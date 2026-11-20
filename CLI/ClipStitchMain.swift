import Foundation

@main
struct ClipStitchMain {
    static let usage = """
    usage: clipstitch [--verbose] [--index-cache <dir>] [--piece-cache <dir>] <job.json> <output-file>
           clipstitch [--verbose] [--index-cache <dir>] --plan <job.json>

    Stitches the clips described by a Stitch Job JSON (see docs/stitch-job.md) into
    one frame-accurate output file, exactly as the Clip Stitcher app would: matching
    clips are stream-copied outside join-boundary GOPs, non-matching clips are
    conformed to the target clip's spec, and the audio is rebuilt sample-aligned.
    An existing file at <output-file> is overwritten. Requires ffmpeg and ffprobe
    (Homebrew or system install).

    --plan writes no media. It probes, indexes and plans the job, prints that plan as
    JSON to stdout, and exits — the one thing the CLI ever puts on stdout. Use it to
    see each clip's treatment, copy/re-encode split and frame count before a render.

    --index-cache <dir> keeps each source's probe, frame index and damage zones in
    <dir>, keyed on the file's identity (path, size, mtime, inode, head/tail hash) and
    the ff-tool and clipstitch builds. A later run on the same source reads them back
    instead of scanning it again. --piece-cache <dir> keeps every re-encoded boundary
    and conformed piece, keyed on its source identity and exact ffmpeg arguments, and
    reuses it in a later render; a reused piece is verified like a fresh one. --plan
    ignores --piece-cache. Without these options nothing is cached.

    Every stage prints its elapsed time on stderr; the run ends with “Total: hh:mm:ss.s”.

    An error prints a bounded excerpt of a long detail (a decoder's output can run to
    thousands of lines); --verbose prints all of it. The last stderr line of every run is
    one verdict line: “Done: <path>”, “Planned: <path>” or “clipstitch: FAILED (…)”.

    exit codes: 0 success · 64 usage · 65 invalid job · 66 probe/index failure ·
    70 export failure
    """

    nonisolated(unsafe) static var verbose = false

    nonisolated(unsafe) static var indexCache: IndexCache?

    nonisolated(unsafe) static var pieceCache: PieceCache?

    static func directoryURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    static func main() async {
        let parsed: ClipStitchArguments.Parsed
        do {
            parsed = try ClipStitchArguments.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            let reason = (error as? ClipStitchArguments.UsageError)?.message ?? describe(error)
            fail(.usage, "\(reason)\n\(usage)")
        }
        verbose = parsed.verbose
        indexCache = parsed.indexCache.map { IndexCache(directory: directoryURL($0)) }
        pieceCache = parsed.pieceCache.map { PieceCache(directory: directoryURL($0)) }
        switch parsed.invocation {
        case .help:
            print(usage)
            exit(0)
        case .plan(let jobPath):
            await plan(job: readJob(at: jobPath), path: jobPath)
        case .stitch(let jobPath, let outputPath):
            // ADR-0035
            WorkDirectorySweeper.sweep()
            await stitch(job: readJob(at: jobPath),
                         output: URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath))
        }
    }

    static func readJob(at path: String) -> StitchJob {
        guard let data = FileManager.default.contents(atPath: (path as NSString).expandingTildeInPath) else {
            fail(.invalidJob, "could not read job file: \(path)")
        }
        do {
            return try StitchJob.parse(data)
        } catch {
            fail(.invalidJob, describe(error))
        }
    }

    static func stitch(job: StitchJob, output: URL) async -> Never {
        do {
            if let required = try StitchPipeline.requiredExtension(job: job),
               output.pathExtension.lowercased() != required {
                fail(.usage, "the job's output container is \(required.uppercased()) — the output file must end in .\(required), not “\(output.lastPathComponent)”")
            }
        } catch {
            fail(.invalidJob, describe(error))
        }
        do {
            let reporter = ProgressReporter()
            let outcome = try await StitchPipeline.run(
                job: job, output: output, log: logToStderr,
                progress: { fraction in reporter.report(fraction) },
                indexCache: indexCache, pieceCache: pieceCache)
            for warning in outcome.warnings {
                FileHandle.standardError.write(Data(("warning: " + warning + "\n").utf8))
            }
            FileHandle.standardError.write(Data("Done: \(output.path)\n".utf8))
            exit(0)
        } catch {
            failRun(error)
        }
    }

    // ADR-0025
    static func plan(job: StitchJob, path: String) async -> Never {
        do {
            let clock = StageClock()
            let prepared = try await StitchPipeline.prepare(job: job, log: logToStderr,
                                                            indexCache: indexCache)
            let data = try PlanReport.make(prepared: prepared).jsonData()
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            logToStderr("Total: \(StageClock.clockLabel(clock.seconds))")
            FileHandle.standardError.write(Data("Planned: \(path)\n".utf8))
            exit(0)
        } catch {
            failRun(error)
        }
    }

    static let logToStderr: (String) -> Void = { line in
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    static func failRun(_ error: Error) -> Never {
        switch error {
        case let error as StitchJobError: fail(.invalidJob, describe(error))
        case let error as FFError: fail(.probeFailure, describe(error))
        default: fail(.exportFailure, describe(error), short: shortForm(error))
        }
    }

    enum ExitCode: Int32 {
        case usage = 64
        case invalidJob = 65
        case probeFailure = 66
        case exportFailure = 70

        var label: String {
            switch self {
            case .usage: return "64 usage"
            case .invalidJob: return "65 invalid job"
            case .probeFailure: return "66 probe/index failure"
            case .exportFailure: return "70 export failure"
            }
        }
    }

    static func fail(_ code: ExitCode, _ message: String, short: String? = nil) -> Never {
        let body = verbose || code == .usage ? message : BoundedExcerpt.bounded(message)
        FileHandle.standardError.write(Data("clipstitch: error: \(body)\n".utf8))
        FileHandle.standardError.write(
            Data("clipstitch: FAILED (\(code.label)): \(oneLine(short ?? message))\n".utf8))
        exit(code.rawValue)
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    static func shortForm(_ error: Error) -> String {
        if case .verificationFailed(let payload)? = error as? ExportError {
            return payload
        }
        return describe(error)
    }

    static func oneLine(_ text: String, limit: Int = 200) -> String {
        let first = text.components(separatedBy: "\n").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return first.count <= limit ? first : String(first.prefix(limit - 1)) + "\u{2026}"
    }

    final class ProgressReporter: @unchecked Sendable {
        private let lock = NSLock()
        private var lastDecile = -1

        func report(_ fraction: Double) {
            let decile = Int(fraction * 10)
            lock.lock()
            let advanced = decile > lastDecile
            if advanced { lastDecile = decile }
            lock.unlock()
            guard advanced else { return }
            FileHandle.standardError.write(Data("progress: \(min(100, decile * 10))%\n".utf8))
        }
    }
}
