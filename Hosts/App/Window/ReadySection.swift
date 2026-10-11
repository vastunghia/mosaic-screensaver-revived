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
                    Text("Updating · \(progress.summary)")
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
            // Whatever the invitation got for an answer, the window says what
            // it means for the photographs.
            if !model.opensAtLogin {
                HStack {
                    Text("Updated only while Mosaic is open")
                    Spacer()
                    Button("Open at Login") { model.setOpensAtLogin(true, reportingAt: .screenSaver) }
                }
            } else if model.loginItem == .requiresApproval {
                HStack {
                    Text("Waiting for approval in System Settings")
                    Spacer()
                    Button("Open Login Items…", action: model.openLoginItemsSettings)
                }
            }
        } header: {
            Label {
                Text("Ready")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        } footer: {
            Footnote(model.loginItem == .enabled
                ? "Mosaic keeps the photographs up to date. Choose it in System Settings, under \(SaverInstaller.whereToChoose)."
                : "Choose Mosaic in System Settings, under \(SaverInstaller.whereToChoose).")
        }
    }
}
