import Foundation

/// The `clipstitch` command line, parsed as pure data (issue #115). Separate from
/// `ClipStitchMain` because that type's job is to exit the process: the parse has to be
/// unit-testable, and nothing that calls `exit` is.
///
/// Options are recognised anywhere among the positional arguments; an unknown `--option`
/// is refused rather than read as a file name, so a mistyped `--pan` can't become a job
/// path and fail two stages later with the wrong exit code.
enum ClipStitchArguments {
    /// What the command line asks for.
    enum Invocation: Equatable {
        /// Print the usage text and exit 0.
        case help
        /// Stitch `job` into `output` — the normal run.
        case stitch(job: String, output: String)
        /// Report what `job` would do, as JSON on stdout, and write no media.
        case plan(job: String)
    }

    struct Parsed: Equatable {
        var invocation: Invocation
        /// `--verbose`: print an error's whole detail instead of the bounded excerpt
        /// (issue #113). Accepted in every mode; stderr only.
        var verbose: Bool = false
        /// `--index-cache <dir>`: keep each source's probe, frame index and damage zones in
        /// `dir` between runs (`IndexCache`). Accepted in every mode.
        var indexCache: String? = nil
        /// `--piece-cache <dir>`: reuse the re-encoded pieces of an earlier render from
        /// `dir` (`PieceCache`). Accepted by `--plan` too, which renders nothing and so
        /// ignores it — one flag set can drive a plan and its render.
        var pieceCache: String? = nil
    }

    /// The options that take a value, as the next argument.
    static let valueOptions: Set<String> = ["--index-cache", "--piece-cache"]

    /// A usage error (exit 64). `message` is the reason alone — the caller appends the
    /// usage text.
    struct UsageError: Error, Equatable {
        var message: String
    }

    /// Parses the arguments after the program name.
    static func parse(_ arguments: [String]) throws -> Parsed {
        if arguments.contains("--help") || arguments.contains("-h") {
            return Parsed(invocation: .help)
        }
        let verbose = arguments.contains("--verbose")
        let plan = arguments.contains("--plan")
        var positional: [String] = []
        var values: [String: String] = [:]
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--verbose", "--plan":
                continue
            case _ where valueOptions.contains(argument):
                guard let value = rest.popFirst(), !value.hasPrefix("--"), !value.isEmpty else {
                    throw UsageError(message: "\(argument) expects a directory")
                }
                guard values[argument] == nil else {
                    throw UsageError(message: "\(argument) is given twice")
                }
                values[argument] = value
            default:
                guard !argument.hasPrefix("--") else {
                    throw UsageError(message: "unknown option “\(argument)”")
                }
                positional.append(argument)
            }
        }
        let indexCache = values["--index-cache"], pieceCache = values["--piece-cache"]
        if plan {
            // A plan query writes no media, so an output file is not merely unused —
            // it would mean the caller expected a render.
            guard positional.count == 1 else {
                return try refusePlanArguments(positional)
            }
            return Parsed(invocation: .plan(job: positional[0]), verbose: verbose,
                          indexCache: indexCache, pieceCache: pieceCache)
        }
        guard positional.count == 2 else {
            throw UsageError(message: "expected a job file and an output file")
        }
        return Parsed(invocation: .stitch(job: positional[0], output: positional[1]), verbose: verbose,
                      indexCache: indexCache, pieceCache: pieceCache)
    }

    private static func refusePlanArguments(_ positional: [String]) throws -> Parsed {
        if positional.count > 1 {
            throw UsageError(message: "--plan writes no media — it takes a job file and no output file")
        }
        throw UsageError(message: "--plan expects a job file")
    }
}
