import Testing
import Foundation
@testable import VidConform

/// Pins the source-row badge logic (issue #31 / ADR-0018): the target row always keeps
/// its Target badge, separate + cut-only marks every other row "Cut only", and every
/// other mode×rendering combination keeps the match verdict against the target.
struct ClipRoleTests {
    private func video(codec: String = "h264") -> VideoProperties {
        VideoProperties(codec: codec, profile: "High", level: "41", width: 1920, height: 1080,
                        frameRate: "25/1", pixelFormat: "yuv420p", fieldOrder: "progressive",
                        sampleAspectRatio: "1:1", colorPrimaries: nil, colorTransfer: nil,
                        colorRange: nil)
    }

    private func clip(codec: String? = "h264") -> Clip {
        var c = Clip(bookmark: Data(), displayName: "c")
        c.video = codec.map { video(codec: $0) }
        return c
    }

    private func settings(mode: OutputMode, rendering: SeparateRendering) -> OutputSettings {
        var s = OutputSettings()
        s.mode = mode
        s.rendering = rendering
        return s
    }

    @Test func theTargetRowKeepsItsBadgeEvenInCutOnly() {
        let target = clip()
        let role = ClipRole.role(for: target, target: target,
                                 output: settings(mode: .separate, rendering: .cutOnly))
        #expect(role == .target)
    }

    @Test func separateCutOnlyMarksNonTargetRowsCutOnly() {
        let role = ClipRole.role(for: clip(codec: "mpeg2video"), target: clip(),
                                 output: settings(mode: .separate, rendering: .cutOnly))
        #expect(role == .cutOnly)
    }

    @Test func cutOnlyNeedsNoProbedVideoForItsVerdict() {
        let role = ClipRole.role(for: clip(codec: nil), target: clip(),
                                 output: settings(mode: .separate, rendering: .cutOnly))
        #expect(role == .cutOnly)
    }

    @Test func separateConformToTargetKeepsTheMatchVerdict() {
        let out = settings(mode: .separate, rendering: .conformToTarget)
        #expect(ClipRole.role(for: clip(), target: clip(), output: out) == .smartRender)
        #expect(ClipRole.role(for: clip(codec: "mpeg2video"), target: clip(), output: out) == .reEncode)
    }

    @Test func connectModeIgnoresTheRenderingChoice() {
        // The choice is a separate-mode sub-setting; a stale cutOnly value must not
        // leak into connect mode's badges.
        let out = settings(mode: .connect, rendering: .cutOnly)
        #expect(ClipRole.role(for: clip(codec: "mpeg2video"), target: clip(), output: out) == .reEncode)
    }

    @Test func noTargetIsUnknownOutsideCutOnly() {
        let out = settings(mode: .separate, rendering: .conformToTarget)
        #expect(ClipRole.role(for: clip(), target: nil, output: out) == .unknown)
    }

    // The badge text doubles as the badge's accessibility value (issue #5) — external
    // probes assert these exact strings, so a rename here is a breaking change for them.
    @Test func badgeTextMatchesTheVisibleStrings() {
        #expect(ClipRole.target.badgeText == "Target")
        #expect(ClipRole.smartRender.badgeText == "Smart render")
        #expect(ClipRole.reEncode.badgeText == "Re-encode")
        #expect(ClipRole.cutOnly.badgeText == "Cut only")
        #expect(ClipRole.unknown.badgeText == nil)
    }
}
