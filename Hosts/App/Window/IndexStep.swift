import PhotoIndex
import SwiftUI

/// The index: what the screen saver reads, built once and kept up to date.
struct IndexStep: View {
    @ObservedObject var model: AppModel
    let number: Int

    var body: some View {
        Section {
            if let progress = model.progress, model.isIndexing {
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                Text(progress.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                HStack {
                    Spacer()
                    Button("Stop", action: model.cancelIndexing)
                }
            } else {
                HStack {
                    Text(counted)
                        .monospacedDigit()
                    Spacer()
                    Button("Update Index", action: model.startIndexing)
                        .disabled(!model.hasPhotographs)
                }
                if let progress = model.progress, progress.skipped + progress.unavailable > 0 {
                    Text(progress.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            StepHeader(number: number, title: "Index", isDone: model.hasIndex)
        } footer: {
            Footnote("It starts on its own once there are photographs, and can take a while: the screen saver works as soon as \(AppModel.minimumPhotographs) are in.")
        }
    }

    private var counted: String {
        let count = model.indexedCount
        if model.hasIndex { return "\(count) photographs indexed" }
        return "\(count) photographs indexed, at least \(AppModel.minimumPhotographs) needed"
    }
}
