import Testing
import Foundation
@testable import VidConform

/// Pins the panel-bypass gate (issue #37): without the exact marker the bypass is
/// unreachable and every flow keeps its panel; with it, paths come from the
/// companion variables.
struct AutomationOverridesTests {
    @Test func withoutTheMarkerThereAreNoOverrides() {
        #expect(AutomationOverrides.fromEnvironment([:]) == nil)
        #expect(AutomationOverrides.fromEnvironment([
            "VIDCONFORM_EXPORT_DEST": "/tmp/out.mp4"
        ]) == nil)
    }

    @Test func theMarkerMustBeExactlyOne() {
        #expect(AutomationOverrides.fromEnvironment(["VIDCONFORM_AUTOMATION": "0"]) == nil)
        #expect(AutomationOverrides.fromEnvironment(["VIDCONFORM_AUTOMATION": "true"]) == nil)
        #expect(AutomationOverrides.fromEnvironment(["VIDCONFORM_AUTOMATION": ""]) == nil)
        #expect(AutomationOverrides.fromEnvironment(["VIDCONFORM_AUTOMATION": "1"]) != nil)
    }

    @Test func theMarkerAloneLeavesEveryFlowOnItsPanel() throws {
        let o = try #require(AutomationOverrides.fromEnvironment(["VIDCONFORM_AUTOMATION": "1"]))
        #expect(o.exportDestination == nil)
        #expect(o.importSources.isEmpty)
        #expect(o.relinkSource == nil)
    }

    @Test func companionVariablesBecomeFileURLs() throws {
        let o = try #require(AutomationOverrides.fromEnvironment([
            "VIDCONFORM_AUTOMATION": "1",
            "VIDCONFORM_EXPORT_DEST": "/tmp/out.mp4",
            "VIDCONFORM_IMPORT_SOURCE": "/tmp/a.mkv\n/tmp/b.mpg",
            "VIDCONFORM_RELINK_SOURCE": "/tmp/moved.ts",
        ]))
        #expect(o.exportDestination == URL(fileURLWithPath: "/tmp/out.mp4"))
        #expect(o.importSources == [URL(fileURLWithPath: "/tmp/a.mkv"),
                                    URL(fileURLWithPath: "/tmp/b.mpg")])
        #expect(o.relinkSource == URL(fileURLWithPath: "/tmp/moved.ts"))
    }

    @Test func blankAndWhitespacePathsAreDropped() throws {
        let o = try #require(AutomationOverrides.fromEnvironment([
            "VIDCONFORM_AUTOMATION": "1",
            "VIDCONFORM_EXPORT_DEST": "   ",
            "VIDCONFORM_IMPORT_SOURCE": "\n  \n/tmp/a.mkv\n",
        ]))
        #expect(o.exportDestination == nil)
        #expect(o.importSources == [URL(fileURLWithPath: "/tmp/a.mkv")])
    }
}
