import PhotoIndex
import SwiftUI

/// Every step done: one section of status in their place, so the window says
/// something new at every launch after the first.
struct ReadySection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section {
            LabeledContent("Photographs") {
                if let progress = model.progress, model.isIndexing {
                    Text("updating · \(progress.summary)")
                        .monospacedDigit()
                } else {
                    Text("\(model.indexedCount.formatted()) ready")
                        .monospacedDigit()
                }
            }
            HStack {
                Text("Screen saver installed")
                Spacer()
                Button("Open Screen Saver Settings…", action: model.openScreenSaverSettings)
            }
        } header: {
            Label {
                Text("Ready")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        } footer: {
            Footnote("Mosaic keeps the photographs up to date. Choose it in the Screen Saver settings, under Other.")
        }
    }
}
