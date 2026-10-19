import AppUpdate
import PhotoIndex
import SwiftUI

/// What the window says under the mosaic: whether the screen saver has what
/// it needs, and what to do where it does not. One section, the same at every
/// launch; the guided setup lives in a window of its own.
struct StatusSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: Updater

    var body: some View {
        Section {
            if model.isTranslocated {
                LocationRow(model: model)
                ProblemRow(model: model, place: .location)
            }
            photographs
            SaverRow(model: model)
            ProblemRow(model: model, place: .screenSaver)
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
            if model.isSetUp {
                Label {
                    Text("Ready")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } else {
                Text("Status")
            }
        } footer: {
            Footnote(Text("Choose Mosaic in System Settings, under \(SaverInstaller.whereToChoose).",
                          comment: "Where the screen saver is chosen; the path is the System Settings sections, as in “Screen Saver › Other”"))
        }
    }

    @ViewBuilder private var photographs: some View {
        if model.preferences.source == .folder, model.preferences.folder == nil {
            LabeledContent("Photographs") { FolderRow(model: model) }
        } else if model.needsAccess {
            PhotosAccessRow(model: model)
        } else if let closeUps = model.closeUps, model.isIndexing {
            switch closeUps {
            case .making(let tried, let of):
                progress(Double(tried), of: Double(of), model.isRenewing
                         ? String(localized: "Making sharp close-ups of the new photographs: \(tried) of \(of)",
                                  comment: "Progress, while new photographs are being chosen")
                         : String(localized: "Making sharp close-ups: \(tried) of \(of)", comment: "Progress"))
            case .downloading(let asked, let of):
                progress(Double(asked), of: Double(of),
                         String(localized: "Downloading sharp close-ups from iCloud: \(asked) of \(of)", comment: "Progress"))
            }
        } else if let progress = model.progress, model.isIndexing {
            self.progress(Double(progress.completed), of: Double(progress.total), model.isRenewing
                          ? String(localized: "Choosing new photographs · \(progress.summary)",
                                   comment: "Progress, followed by the index figures")
                          : String(localized: "Preparing · \(progress.summary)",
                                   comment: "Progress, followed by the index figures"))
        } else {
            LabeledContent("Photographs") {
                Text(ready).monospacedDigit()
            }
            if let progress = model.progress, progress.skipped + progress.unavailable > 0 {
                note(progress.summary)
            }
            // Filling to the number chosen ran out of photographs: say why
            // there are fewer, or it looks like the setting was ignored.
            if let progress = model.progress, progress.fellShort {
                note(String(localized: "That is every photograph this Mac can use: the others are only in iCloud or unreadable.",
                            comment: "Under the count of photographs, when there are fewer than the number chosen"))
            }
        }
        if let waiting = model.closeUpsWaiting, !model.isIndexing {
            HStack {
                note(waiting.summary)
                if waiting.reason == .limits {
                    Spacer()
                    DownloadLimitsReset(model: model)
                }
            }
        }
        if model.advisesDownloads, !model.isIndexing {
            HStack {
                note(String(localized: "\(model.closeUpsNotHere) photographs shown full screen have blurry close-ups: their originals are in iCloud.",
                            comment: "Advice to allow downloads from iCloud"))
                Spacer()
                Button("Download Settings…", action: MosaicApplication.showSettings)
            }
        }
        ProblemRow(model: model, place: .photographs)
        ProblemRow(model: model, place: .preparing)
    }

    private var ready: String {
        let count = model.indexedCount
        if model.hasIndex {
            return String(localized: "\(count) ready", comment: "Photographs ready for the screen saver")
        }
        return String(localized: "\(count) ready, at least \(AppModel.minimumPhotographs) needed",
                      comment: "Photographs ready for the screen saver, fewer than it needs")
    }

    private func progress(_ value: Double, of total: Double, _ text: String) -> some View {
        VStack(alignment: .leading) {
            ProgressView(value: value, total: max(total, 1))
            HStack {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Stop", action: model.cancelIndexing)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}
