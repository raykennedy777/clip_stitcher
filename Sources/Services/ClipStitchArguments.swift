import Foundation

enum ClipStitchArguments {
    enum Invocation: Equatable {
        case help
        case stitch(job: String, output: String)
        case plan(job: String)
    }

    struct Parsed: Equatable {
        var invocation: Invocation
        var verbose: Bool = false
        var indexCache: String? = nil
        var pieceCache: String? = nil
    }

    static let valueOptions: Set<String> = ["--index-cache", "--piece-cache"]

    struct UsageError: Error, Equatable {
        var message: String
    }

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
