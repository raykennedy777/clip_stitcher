import Testing
@testable import ClipStitcher

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

    @Test func cacheOptionsTakeADirectoryInAnyPosition() throws {
        let parsed = try ClipStitchArguments.parse(
            ["--index-cache", "/c/index", "job.json", "--piece-cache", "/c/pieces", "out.mkv"])
        #expect(parsed == ClipStitchArguments.Parsed(
            invocation: .stitch(job: "job.json", output: "out.mkv"),
            indexCache: "/c/index", pieceCache: "/c/pieces"))
    }

    @Test func planAcceptsBothCacheOptions() throws {
        let parsed = try ClipStitchArguments.parse(
            ["--plan", "job.json", "--index-cache", "/c/index", "--piece-cache", "/c/pieces"])
        #expect(parsed.invocation == .plan(job: "job.json"))
        #expect(parsed.indexCache == "/c/index")
        #expect(parsed.pieceCache == "/c/pieces")
    }

    @Test func cachesAreOffByDefault() throws {
        let parsed = try ClipStitchArguments.parse(["job.json", "out.mkv"])
        #expect(parsed.indexCache == nil)
        #expect(parsed.pieceCache == nil)
    }

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
