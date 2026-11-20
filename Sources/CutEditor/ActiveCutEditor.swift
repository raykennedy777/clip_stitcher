import SwiftUI

// ADR-0037
@MainActor
final class ActiveCutEditor: ObservableObject {
    static let shared = ActiveCutEditor()

    @Published private(set) var model: CutEditorModel?

    init() {}

    func activate(_ model: CutEditorModel) {
        self.model = model
    }

    func resign(_ model: CutEditorModel?) {
        if self.model === model {
            self.model = nil
        }
    }
}
