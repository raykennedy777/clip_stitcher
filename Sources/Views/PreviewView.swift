import SwiftUI

/// Placeholder for the whole-timeline output preview (sidebar "Preview").
/// Implemented in a later slice; see docs/ROADMAP.md.
struct PreviewView: View {
    var body: some View {
        ContentUnavailableView(
            "Output Preview",
            systemImage: "play.rectangle",
            description: Text("Playback of the assembled timeline comes in a later slice.")
        )
        .navigationTitle("Preview")
    }
}
