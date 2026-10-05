import Testing
@testable import ClipStitcher

/// The `clipstitch` command line (issue #115). Parsing is pure data so it can be tested
/// at all: `ClipStitchMain` exits the process, and nothing that calls `exit` is testable.
struct ClipStitchArgumentsTests {

    @Test func stitchTakesAJobFileAndAnOutputFile() throws {
        let parsed = try ClipStitchArguments.parse(["job.json", "out.mkv"])
        #expect(parsed == ClipStitchArguments.Parsed(
            invocation: .stitch(job: "job.json", output: "out.mkv"), verbose: false))
    }

    @Test func planTakesAJobFileAlone() throws {
        let parsed = try ClipStitchArguments.parse(["--plan", "job.json"])
        #expect(parsed.invocation == .plan(job: "job.json"))
    }

    /// The usage refusal the issue asks for: a plan query writes no media, so an output
    /// file means the caller expected a render — exit 64, before any probe runs.
    @Test func planRefusesASecondPositionalArgument() {
        #expect(throws: ClipStitchArguments.UsageError.self) {
            try ClipStitchArguments.parse(["--plan", "job.json", "out.mkv"])
        }
    }

    @Test func planRefusesNoJobFile() {
        #expect(throws: ClipStitchArguments.UsageError.self) {
            try ClipStitchArguments.parse(["--plan"])
        }
    }

    @Test func stitchRefusesTheWrongNumberOfFiles() {
        #expect(throws: ClipStitchArguments.UsageError.self) {
            try ClipStitchArguments.parse(["job.json"])
        }
        #expect(throws: ClipStitchArguments.UsageError.self) {
            try ClipStitchArguments.parse(["job.json", "out.mkv", "extra.mkv"])
        }
    }

    /// A mistyped option is refused as usage rather than read as a file name — otherwise
    /// `--pan job.json` would become a two-file stitch and fail one stage later with the
    /// wrong exit code.
    @Test func anUnknownOptionIsAUsageError() {
        #expect(throws: ClipStitchArguments.UsageError.self) {
            try ClipStitchArguments.parse(["--pan", "job.json"])
        }
    }

    @Test func verboseIsAcceptedInEveryModeAndInAnyPosition() throws {
        #expect(try ClipStitchArguments.parse(["--verbose", "job.json", "out.mkv"]).verbose)
        #expect(try ClipStitchArguments.parse(["job.json", "--verbose", "out.mkv"]).verbose)
        let plan = try ClipStitchArguments.parse(["--plan", "job.json", "--verbose"])
        #expect(plan == ClipStitchArguments.Parsed(invocation: .plan(job: "job.json"), verbose: true))
    }

    @Test func helpWinsOverEverythingElse() throws {
        #expect(try ClipStitchArguments.parse(["--help"]).invocation == .help)
        #expect(try ClipStitchArguments.parse(["--plan", "job.json", "-h"]).invocation == .help)
    }

    // MARK: - Cache directories

    @Test func cacheOptionsTakeADirectoryInAnyPosition() throws {
        let parsed = try ClipStitchArguments.parse(
            ["--index-cache", "/c/index", "job.json", "--piece-cache", "/c/pieces", "out.mkv"])
        #expect(parsed == ClipStitchArguments.Parsed(
            invocation: .stitch(job: "job.json", output: "out.mkv"),
            indexCache: "/c/index", pieceCache: "/c/pieces"))
    }

    /// One flag set drives a plan and its render, so `--plan` accepts both caches.
    @Test func planAcceptsBothCacheOptions() throws {
        let parsed = try ClipStitchArguments.parse(
            ["--plan", "job.json", "--index-cache", "/c/index", "--piece-cache", "/c/pieces"])
        #expect(parsed.invocation == .plan(job: "job.json"))
        #expect(parsed.indexCache == "/c/index")
        #expect(parsed.pieceCache == "/c/pieces")
    }

    /// Without the options no cache is used — today's behaviour.
    @Test func cachesAreOffByDefault() throws {
        let parsed = try ClipStitchArguments.parse(["job.json", "out.mkv"])
        #expect(parsed.indexCache == nil)
        #expect(parsed.pieceCache == nil)
    }

    /// A missing directory must not swallow the next option or a positional file.
    @Test func aCacheOptionWithoutADirectoryIsAUsageError() {
        #expect(throws: ClipStitchArguments.UsageError.self) {
            try ClipStitchArguments.parse(["job.json", "out.mkv", "--index-cache"])
        }
        #expect(throws: ClipStitchArguments.UsageError.self) {
            try ClipStitchArguments.parse(["--piece-cache", "--verbose", "job.json", "out.mkv"])
        }
        #expect(throws: ClipStitchArguments.UsageError.self) {
            try ClipStitchArguments.parse(["--index-cache", "/a", "--index-cache", "/b", "job.json", "out.mkv"])
        }
    }
}
