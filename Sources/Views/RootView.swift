import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case source, output, preview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .source: return "Source"
        case .output: return "Output"
        case .preview: return "Preview"
        }
    }

    var symbol: String {
        switch self {
        case .source: return "film.stack"
        case .output: return "square.and.arrow.up"
        case .preview: return "play.rectangle"
        }
    }
}

struct RootView: View {
    @ObservedObject var document: ProjectDocument
    @Environment(\.undoManager) private var undoManager
    @StateObject private var cutEditor = CutEditorPresenter()
    @State private var section: AppSection? = .source

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            switch section ?? .source {
            case .source: SourceView(document: document)
            case .output: OutputView(document: document)
            case .preview: PreviewView()
            }
        }
        .environmentObject(cutEditor)
        .onAppear { document.undoManager = undoManager }
    }
}
