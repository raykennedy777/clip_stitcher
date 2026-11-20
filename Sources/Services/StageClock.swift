import Foundation

struct StageClock {
    private let start = ContinuousClock.now

    var seconds: Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    var label: String { Self.label(seconds) }

    static func label(_ seconds: Double) -> String {
        String(format: "%.2f s", seconds)
    }

    static func clockLabel(_ seconds: Double) -> String {
        let tenths = Int((seconds * 10).rounded())
        return String(format: "%02d:%02d:%02d.%d",
                      tenths / 36000, (tenths / 600) % 60, (tenths / 10) % 60, tenths % 10)
    }

    static func fpsLabel(frames: Int, seconds: Double) -> String? {
        guard seconds > 0.0005, frames > 0 else { return nil }
        return String(format: "%.1f fps", Double(frames) / seconds)
    }

    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}
