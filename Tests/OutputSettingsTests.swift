import Testing
import Foundation
@testable import ClipStitcher

struct OutputSettingsTests {
    @Test func anOldSaveWithoutRenderingDecodesToConformToTarget() throws {
        let old = #"{"mode":"separate","type":"videoAndAudio","container":"ts"}"#
        let decoded = try JSONDecoder().decode(OutputSettings.self, from: Data(old.utf8))
        #expect(decoded.rendering == .conformToTarget)
        #expect(decoded.mode == .separate)
        #expect(decoded.container == .ts)
    }

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

    @Test func anOldSaveWithoutConformCrfDecodesToNil() throws {
        let old = #"{"mode":"connect","type":"videoAndAudio","container":"mkv"}"#
        let decoded = try JSONDecoder().decode(OutputSettings.self, from: Data(old.utf8))
        #expect(decoded.conformCrf == nil)
        #expect(OutputSettings().conformCrf == nil)
    }

    @Test func conformCrfSurvivesARoundTrip() throws {
        var settings = OutputSettings()
        settings.conformCrf = 21
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(OutputSettings.self, from: data)
        #expect(decoded.conformCrf == 21)
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
