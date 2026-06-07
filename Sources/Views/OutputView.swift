import SwiftUI

struct OutputView: View {
    @ObservedObject var document: ProjectDocument

    private var output: Binding<OutputSettings> {
        Binding(
            get: { document.project.output },
            set: { document.setOutput($0) }
        )
    }

    var body: some View {
        Form {
            Section("Output") {
                Picker("Mode", selection: output.mode) {
                    ForEach(OutputMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("Type", selection: output.type) {
                    ForEach(OutputType.allCases) { Text($0.title).tag($0) }
                }
                Picker("Container", selection: output.container) {
                    ForEach(Container.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Output")
    }
}
