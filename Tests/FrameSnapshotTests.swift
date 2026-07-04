import Testing
import Foundation
@testable import ClipStitcher

/// The still-image filename builder (issue #89) — filesystem-safe across volumes.
struct FrameSnapshotTests {
    @Test func fileNameStripsExtensionAndMakesTimecodeSafe() {
        // The clip's own extension is dropped; the timecode's colons become dots so the
        // name is unambiguous in Finder (which renders ":" as "/").
        #expect(FrameSnapshot.fileName(clipName: "race.ts", timecode: "00:01:23:04")
                == "race — 00.01.23.04.png")
        #expect(FrameSnapshot.fileName(clipName: "clip.mkv", timecode: "01:00:00:12")
                == "clip — 01.00.00.12.png")
    }

    @Test func fileNameKeepsDottedNamesIntactApartFromTheLastExtension() {
        // Only the trailing path extension is dropped — dots inside the stem survive.
        #expect(FrameSnapshot.fileName(clipName: "MotoGP.2005.Round04.mkv", timecode: "00:00:10:00")
                == "MotoGP.2005.Round04 — 00.00.10.00.png")
    }

    @Test func fileNameFallsBackWhenTheStemIsEmpty() {
        #expect(FrameSnapshot.fileName(clipName: "", timecode: "00:00:00:00")
                == "Frame — 00.00.00.00.png")
    }
}
