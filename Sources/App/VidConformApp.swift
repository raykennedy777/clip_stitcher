import SwiftUI

@main
struct VidConformApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { ProjectDocument() }) { configuration in
            RootView(document: configuration.document)
        }
    }
}
