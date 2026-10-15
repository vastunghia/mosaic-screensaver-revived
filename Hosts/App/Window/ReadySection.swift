import AppUpdate
import PhotoIndex
import SwiftUI

/// Every step done: one section of status in their place, so the window says
/// something new at every launch after the first.
struct ReadySection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: Updater

    var body: some View {
        Section {
            LabeledContent("Photographs") {
                if let fetching = model.fetchingCloseUps, model.isIndexing {
                    Text("Downloading sharp close-ups · \(fetching.asked) of \(fetching.of)")
                        .monospacedDigit()
                } else if let progress = model.progress, model.isIndexing {
                    Text("Updating · \(progress.summary)")
                        .monospacedDigit()
                } else {
                    Text("\(model.indexedCount.formatted()) ready")
                        .monospacedDigit()
                }
            }
            if let waiting = model.closeUpsWaiting, !model.isIndexing {
                HStack {
                    Text(waiting.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if waiting.reason == .limits {
                        Spacer()
                        DownloadLimitsReset(model: model)
                    }
                }
            }
            HStack {
                Text("Screen saver installed")
                Spacer()
                Button("Open Screen Saver Settings…", action: model.openScreenSaverSettings)
            }
            switch updater.state {
            case .preparing(let version):
                Text("Downloading Mosaic \(version.description)…")
                    .foregroundStyle(.secondary)
            case .ready(let release, _):
                HStack {
                    Text("Mosaic \(release.version.description) is available")
                    Spacer()
                    Button("Install…", action: MosaicApplication.offerUpdate)
                }
            case .idle, .checking, .installing:
                EmptyView()
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
