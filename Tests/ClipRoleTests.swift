import Testing
import Foundation
@testable import ClipStitcher

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
        let out = settings(mode: .connect, rendering: .cutOnly)
        #expect(ClipRole.role(for: clip(codec: "mpeg2video"), target: clip(), output: out) == .reEncode)
    }

    @Test func noTargetIsUnknownOutsideCutOnly() {
        let out = settings(mode: .separate, rendering: .conformToTarget)
        #expect(ClipRole.role(for: clip(), target: nil, output: out) == .unknown)
    }

    @Test func badgeTextMatchesTheVisibleStrings() {
        #expect(ClipRole.target.badgeText == "Target")
        #expect(ClipRole.smartRender.badgeText == "Smart render")
        #expect(ClipRole.reEncode.badgeText == "Re-encode")
        #expect(ClipRole.cutOnly.badgeText == "Cut only")
        #expect(ClipRole.unknown.badgeText == nil)
    }
}
