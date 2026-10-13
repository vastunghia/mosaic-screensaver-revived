import PhotoIndex
import SwiftUI

/// The photographs made ready for the mosaics: the index the screen saver
/// reads, built once and kept up to date by itself.
struct PreparationStep: View {
    @ObservedObject var model: AppModel
    let number: Int

    var body: some View {
        Section {
            if let fetching = model.fetchingCloseUps, model.isIndexing {
                ProgressView(value: Double(fetching.asked), total: Double(max(fetching.of, 1)))
                HStack {
                    Text("Downloading sharp close-ups from iCloud: \(fetching.asked) of \(fetching.of)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Button("Stop", action: model.cancelIndexing)
                }
            } else if let progress = model.progress, model.isIndexing {
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
                // Filling to the number chosen ran out of photographs: say why
                // there are fewer, or it looks like the setting was ignored.
                if let progress = model.progress, progress.fellShort {
                    Text("That is every photograph this Mac can use: the others are only in iCloud or unreadable.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            ProblemRow(model: model, place: .preparing)
        } header: {
            StepHeader(number: number, title: "Preparation", isDone: model.hasIndex)
        } footer: {
            // Keeping the photographs up to date is this step's, and happens
            // without the window only once Mosaic opens at login: said of
            // every user, it misled those who had not turned it on (Sergio,
            // 2026-10-13).
            if model.opensAtLogin {
                Footnote("It starts by itself and can take a while; the screen saver works as soon as \(AppModel.minimumPhotographs) photographs are ready. Mosaic also opens at login, without a window, to keep them up to date; Mosaic Settings turns that off.")
            } else {
                Footnote("It starts by itself and can take a while; the screen saver works as soon as \(AppModel.minimumPhotographs) photographs are ready. Mosaic keeps them up to date while it is open; to do it without opening this window, turn on Open at login in Mosaic Settings.")
            }
        }
    }

    private var ready: String {
        let count = model.indexedCount.formatted()
        if model.hasIndex { return "\(count) photographs ready" }
        return "\(count) photographs ready, at least \(AppModel.minimumPhotographs) needed"
    }
}
