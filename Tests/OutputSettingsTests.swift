import Testing
import Foundation
@testable import VidConform

/// Pins `OutputSettings` decoding across save vintages: the `rendering` choice arrived
/// with ADR-0018, and saves made before it must decode to conform-to-target — today's
/// behavior — rather than failing the whole project file.
struct OutputSettingsTests {
    @Test func anOldSaveWithoutRenderingDecodesToConformToTarget() throws {
        let old = #"{"mode":"separate","type":"videoAndAudio","container":"ts"}"#
        let decoded = try JSONDecoder().decode(OutputSettings.self, from: Data(old.utf8))
        #expect(decoded.rendering == .conformToTarget)
        #expect(decoded.mode == .separate)
        #expect(decoded.container == .ts)
    }

    // MKV is the unconditional default container (issue #10): the only supported
    // container that round-trips audio track titles (ADR-0014), and since issue #2 it
    // carries MPEG-2 by stream-copy too — no per-codec override on first import.
    @Test func freshSettingsDefaultToMkv() {
        #expect(OutputSettings().container == .mkv)
    }

    @Test func anOldSaveWithoutContainerDecodesToTheMkvDefault() throws {
        let old = #"{"mode":"connect","type":"videoAndAudio"}"#
        let decoded = try JSONDecoder().decode(OutputSettings.self, from: Data(old.utf8))
        #expect(decoded.container == .mkv)
    }

    @Test func anExplicitContainerChoiceSurvivesDecoding() throws {
        let saved = #"{"mode":"connect","type":"videoAndAudio","container":"mp4"}"#
        let decoded = try JSONDecoder().decode(OutputSettings.self, from: Data(saved.utf8))
        #expect(decoded.container == .mp4)
    }

    @Test func cutOnlySurvivesARoundTrip() throws {
        var settings = OutputSettings()
        settings.mode = .separate
        settings.rendering = .cutOnly
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(OutputSettings.self, from: data)
        #expect(decoded == settings)
    }
}
