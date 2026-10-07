import PhotoIndex
import SwiftUI

/// The photographs made ready for the mosaics: the index the screen saver
/// reads, built once and kept up to date by itself.
struct PreparationStep: View {
    @ObservedObject var model: AppModel
    let number: Int

    var body: some View {
        Section {
            if let progress = model.progress, model.isIndexing {
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                HStack {
                    Text(progress.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Button("Stop", action: model.cancelIndexing)
                }
            } else {
                Text(ready)
                    .monospacedDigit()
                if let progress = model.progress, progress.skipped + progress.unavailable > 0 {
                    Text(progress.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            ProblemRow(model: model, place: .preparing)
        } header: {
            StepHeader(number: number, title: "Preparation", isDone: model.hasIndex)
        } footer: {
            Footnote("It starts by itself and can take a while; the screen saver works as soon as \(AppModel.minimumPhotographs) photographs are ready. Mosaic keeps them up to date.")
        }
    }

    private var ready: String {
        let count = model.indexedCount.formatted()
        if model.hasIndex { return "\(count) photographs ready" }
        return "\(count) photographs ready, at least \(AppModel.minimumPhotographs) needed"
    }
}
