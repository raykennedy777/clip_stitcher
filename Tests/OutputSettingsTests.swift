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

    @Test func cutOnlySurvivesARoundTrip() throws {
        var settings = OutputSettings()
        settings.mode = .separate
        settings.rendering = .cutOnly
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(OutputSettings.self, from: data)
        #expect(decoded == settings)
    }
}
