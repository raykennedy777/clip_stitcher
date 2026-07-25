import Foundation

/// `clipstitch` — the headless CLI over the app's stitching engine (issue #105,
/// ADR-0025): a Stitch Job JSON in, a frame-accurate stitched file out, no GUI and no
/// user interaction. All human-readable output (stage lines, warnings, errors) goes to
/// **stderr**; stdout stays silent so the exit code and the output file are the whole
/// scriptable surface.
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
    usage: clipstitch <job.json> <output-file>

    Stitches the clips described by a Stitch Job JSON (see docs/stitch-job.md) into
    one frame-accurate output file, exactly as the Clip Stitcher app would: matching
    clips are stream-copied outside join-boundary GOPs, non-matching clips are
    conformed to the target clip's spec, and the audio is rebuilt sample-aligned.
    An existing file at <output-file> is overwritten. Requires ffmpeg and ffprobe
    (Homebrew or system install).

    exit codes: 0 success · 64 usage · 65 invalid job · 66 probe/index failure ·
    70 export failure
    """

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            exit(0)
        }
        guard arguments.count == 2 else {
            fail(.usage, "expected a job file and an output file\n\(usage)")
        }
        // Reclaim the work directories a previous hard kill abandoned (issue #109). The CLI
        // leaks the same way the app does on ^C/SIGTERM, and an AFK render batch may never
        // launch the app to sweep for it. Synchronous — the CLI is short-lived, so a detached
        // task could be cut off by `exit` — and cheap: a directory listing, plus the unlinks
        // for whatever it condemns. Logged, never printed: stderr stays the job's own output.
        WorkDirectorySweeper.sweep()
        let jobPath = (arguments[0] as NSString).expandingTildeInPath
        let outputPath = (arguments[1] as NSString).expandingTildeInPath

        guard let data = FileManager.default.contents(atPath: jobPath) else {
            fail(.invalidJob, "could not read job file: \(arguments[0])")
        }
        let job: StitchJob
        do {
            job = try StitchJob.parse(data)
        } catch {
            fail(.invalidJob, describe(error))
        }

        let output = URL(fileURLWithPath: outputPath)
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
                job: job, output: output,
                log: { line in FileHandle.standardError.write(Data((line + "\n").utf8)) },
                progress: { fraction in reporter.report(fraction) })
            for warning in outcome.warnings {
                FileHandle.standardError.write(Data(("warning: " + warning + "\n").utf8))
            }
            FileHandle.standardError.write(Data("Done: \(output.path)\n".utf8))
            exit(0)
        } catch let error as StitchJobError {
            fail(.invalidJob, describe(error))
        } catch let error as FFError {
            fail(.probeFailure, describe(error))
        } catch {
            fail(.exportFailure, describe(error))
        }
    }

    enum ExitCode: Int32 {
        case usage = 64          // EX_USAGE
        case invalidJob = 65     // EX_DATAERR
        case probeFailure = 66   // EX_NOINPUT
        case exportFailure = 70  // EX_SOFTWARE
    }

    static func fail(_ code: ExitCode, _ message: String) -> Never {
        FileHandle.standardError.write(Data("clipstitch: error: \(message)\n".utf8))
        exit(code.rawValue)
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
