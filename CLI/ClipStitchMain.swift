import Foundation

/// `clipstitch` — the headless CLI over the app's stitching engine (issue #105,
/// ADR-0025): a Stitch Job JSON in, a frame-accurate stitched file out, no GUI and no
/// user interaction. All human-readable output (stage lines, warnings, errors) goes to
/// **stderr**; stdout stays silent so the exit code and the output file are the whole
/// scriptable surface. `--plan` is the one exception (issue #115): that flag is a query,
/// its answer is a JSON document, and the document goes to stdout.
///
/// Exit codes (sysexits-flavored, documented in docs/stitch-job.md):
///   0   success
///   64  usage error (bad arguments, wrong output extension)
///   65  invalid job (unreadable/malformed job file, or a job that doesn't fit its sources)
///   66  probe/index failure (a source couldn't be read, or ffmpeg/ffprobe is missing)
///   70  export failure (planning or producing the output failed)
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

    /// `--verbose` prints an error's whole detail instead of the bounded excerpt (issue #113).
    /// stderr only — stdout stays silent whatever the flag.
    nonisolated(unsafe) static var verbose = false

    /// `--index-cache <dir>`, or nil when the run caches no source facts.
    nonisolated(unsafe) static var indexCache: IndexCache?

    /// `--piece-cache <dir>`, or nil when the render reuses no pieces.
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
            // Reclaim the work directories a previous hard kill abandoned (issue #109). The
            // CLI leaks the same way the app does on ^C/SIGTERM, and an AFK render batch may
            // never launch the app to sweep for it. Synchronous — the CLI is short-lived, so
            // a detached task could be cut off by `exit` — and cheap: a directory listing,
            // plus the unlinks for whatever it condemns. Logged, never printed: stderr stays
            // the job's own output. A plan query never reaches it: a query unlinks nothing.
            WorkDirectorySweeper.sweep()
            await stitch(job: readJob(at: jobPath),
                         output: URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath))
        }
    }

    /// Reads and validates the job file, or exits with the invalid-job code.
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

    /// The normal run: stitch the job into `output` and report the verdict on stderr.
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

    /// Answers `--plan` (issue #115): probe, index and plan the job, then print the plan
    /// as JSON on **stdout** and exit. This is the CLI's one deliberate stdout exception —
    /// the flag is a query, and its answer is the output, so a caller reads it with no log
    /// parsing. Stage lines and the verdict stay on stderr, so `--plan job.json 2>/dev/null`
    /// is the JSON alone. No encoder runs and no file is written.
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

    /// The pipeline's stage lines, on stderr where all human-readable output goes.
    static let logToStderr: (String) -> Void = { line in
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Maps a pipeline error onto its exit code. The classes are load-bearing
    /// (`StitchPipeline`): a job-class error is the caller's job file, an `FFError` is a
    /// source or a missing tool, anything else is planning or producing the output. A run
    /// and a plan query share this map so one job's failure gets one code either way.
    static func failRun(_ error: Error) -> Never {
        switch error {
        case let error as StitchJobError: fail(.invalidJob, describe(error))
        case let error as FFError: fail(.probeFailure, describe(error))
        default: fail(.exportFailure, describe(error), short: shortForm(error))
        }
    }

    enum ExitCode: Int32 {
        case usage = 64          // EX_USAGE
        case invalidJob = 65     // EX_DATAERR
        case probeFailure = 66   // EX_NOINPUT
        case exportFailure = 70  // EX_SOFTWARE

        /// The verdict line's name for this code, for example “70 export failure”.
        var label: String {
            switch self {
            case .usage: return "64 usage"
            case .invalidJob: return "65 invalid job"
            case .probeFailure: return "66 probe/index failure"
            case .exportFailure: return "70 export failure"
            }
        }
    }

    /// Prints the error, then the verdict line, then exits (issue #113). The verdict is the
    /// **last** stderr line of the run, so `tail -1` of a piped log is the outcome — the
    /// message above it can be thousands of decoder lines long. `short` is the verdict's own
    /// one-line summary; it defaults to the message's first line, and never wraps a newline
    /// into the verdict. A usage error prints whole: its message is the fixed usage text,
    /// not an unbounded detail, and an excerpt of it would help no one.
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

    /// The verdict's short form for an export error. A verification refusal carries its
    /// location line as the first line of its own payload (issue #113) — the same text the
    /// message shows, so there is no second source of truth — while
    /// `errorDescription` puts a fixed preamble above it. Any other error uses its
    /// description's first line.
    static func shortForm(_ error: Error) -> String {
        if case .verificationFailed(let payload)? = error as? ExportError {
            return payload
        }
        return describe(error)
    }

    /// The first line of `text`, trimmed and capped, for the one-line verdict.
    static func oneLine(_ text: String, limit: Int = 200) -> String {
        let first = text.components(separatedBy: "\n").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return first.count <= limit ? first : String(first.prefix(limit - 1)) + "\u{2026}"
    }

    /// Serializes the engine's cross-queue progress callbacks into coarse stderr
    /// lines — one per 10 % step, so a long export shows life without flooding logs.
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
