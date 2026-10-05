import Foundation

/// The wall clock behind the CLI's stage-timing lines (R5 of the 2026 R16 clipstitch
/// review). A render used to show only "Indexing…" and decile progress, so a slow run
/// could not say which stage held it. Each stage line now ends with its elapsed time and
/// its counters. The lines go to `log`, which the CLI sends to stderr; nothing here
/// touches a command line or an output file.
struct StageClock {
    private let start = ContinuousClock.now

    /// The seconds since this clock was made.
    var seconds: Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    /// The elapsed time as a stage line spells it, for example `9.81 s`.
    var label: String { Self.label(seconds) }

    static func label(_ seconds: Double) -> String {
        String(format: "%.2f s", seconds)
    }

    /// A run total as `hh:mm:ss.s`, the shape the motogp_muxing slot logs use.
    static func clockLabel(_ seconds: Double) -> String {
        let tenths = Int((seconds * 10).rounded())
        return String(format: "%02d:%02d:%02d.%d",
                      tenths / 36000, (tenths / 600) % 60, (tenths / 10) % 60, tenths % 10)
    }

    /// Frames per second for a run, or `nil` when the run took no measurable time.
    static func fpsLabel(frames: Int, seconds: Double) -> String? {
        guard seconds > 0.0005, frames > 0 else { return nil }
        return String(format: "%.1f fps", Double(frames) / seconds)
    }

    /// `1 zone` / `3 zones` — the stage lines' counter spelling.
    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}
