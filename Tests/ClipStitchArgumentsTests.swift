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
}
