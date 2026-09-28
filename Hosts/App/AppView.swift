import MosaicPhotoKit
import MosaicPhotos
import PhotoIndex
import SwiftUI

/// The app's one window: where the photographs come from, the index, the two
/// settings the original exposed, and Play.
struct AppView: View {
    @ObservedObject var model: AppModel
    let play: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                sourceSection
                if model.preferences.source == .photos {
                    photosSection
                } else {
                    folderSection
                }
                indexSection
                effectSection
            }
            .formStyle(.grouped)

            HStack {
                if let error = model.lastError {
                    Text(error)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .font(.callout)
                }
                Spacer()
                Button("Play", action: play)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canPlay)
                    .help(model.canPlay
                          ? "Full screen. Any key or click ends it."
                          : "Needs at least \(AppModel.minimumPhotographs) indexed photographs.")
            }
            .padding()
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 560, idealHeight: 720)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAccess()
        }
    }

    // MARK: Sections

    private var sourceSection: some View {
        Section {
            Picker("Photographs from", selection: $model.preferences.source) {
                Text("Photos library").tag(AppPreferences.Source.photos)
                Text("A folder").tag(AppPreferences.Source.folder)
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var photosSection: some View {
        Section("Photos library") {
            accessRow
            if model.access.isGranted {
                Toggle("Download photographs kept only in iCloud", isOn: $model.preferences.allowsDownloads)
                Picker("Which photographs", selection: $model.preferences.subsetRule) {
                    Text("Random").tag(SubsetRule.random)
                    Text("Most recent").tag(SubsetRule.recent)
                    Text("Spread over time").tag(SubsetRule.uniformInTime)
                }
                Stepper(
                    "How many: \(model.preferences.subsetSize)",
                    value: $model.preferences.subsetSize,
                    in: 100...20_000,
                    step: 512
                )
            }
        }
        if model.access.isGranted {
            Section {
                albumRow(title: "All photographs", count: nil,
                         isOn: model.preferences.albumIdentifiers.isEmpty) {
                    model.preferences.albumIdentifiers = []
                }
                ForEach(model.albums) { album in
                    albumRow(title: album.title, count: album.count,
                             isOn: model.preferences.albumIdentifiers.contains(album.id)) {
                        model.toggleAlbum(album.id)
                    }
                }
            } header: {
                Text("Albums")
            } footer: {
                Text("None chosen is the whole library; several are combined.")
            }
        }
    }

    @ViewBuilder
    private var accessRow: some View {
        switch model.access {
        case .notDetermined:
            HStack {
                Text("Mosaic needs to read your photo library.")
                Spacer()
                Button("Allow Access…") { model.requestAccess() }
            }
        case .authorized:
            Label("Access granted", systemImage: "checkmark.circle")
        case .limited:
            HStack {
                Label("Limited to the photographs you picked", systemImage: "circle.lefthalf.filled")
                Spacer()
                Button("Change…") { model.openPrivacySettings() }
            }
        case .denied, .restricted:
            HStack {
                Label(model.access == .denied ? "Access was refused" : "Access is restricted on this Mac",
                      systemImage: "xmark.circle")
                Spacer()
                Button("Open System Settings…") { model.openPrivacySettings() }
            }
        }
    }

    private func albumRow(title: String, count: Int?, isOn: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                Text(title)
                Spacer()
                if let count {
                    Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var folderSection: some View {
        Section("Folder") {
            HStack {
                Text(model.preferences.folder?.path ?? "None chosen")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(model.preferences.folder == nil ? .secondary : .primary)
                Spacer()
                Button("Choose…") { model.chooseFolder() }
            }
        }
    }

    private var indexSection: some View {
        Section("Index") {
            if let progress = model.progress, model.isIndexing {
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                Text(describe(progress))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text("\(model.indexedCount) photographs indexed")
                    .monospacedDigit()
                if let progress = model.progress, progress.skipped + progress.unavailable > 0 {
                    Text(describe(progress))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                if model.isIndexing {
                    Button("Stop") { model.cancelIndexing() }
                } else {
                    Button("Update Index") { model.startIndexing() }
                        .disabled(!model.preferences.hasSource || model.needsAccess)
                }
            }
        }
    }

    private var effectSection: some View {
        Section("Mosaic") {
            LabeledContent("Rows") {
                HStack {
                    Slider(
                        value: Binding(
                            get: { Double(model.preferences.rows) },
                            set: { model.preferences.rows = Int($0.rounded()) }
                        ),
                        in: Double(AppPreferences.rowRange.lowerBound)...Double(AppPreferences.rowRange.upperBound),
                        step: 1
                    )
                    Text("\(model.preferences.rows)").monospacedDigit().frame(width: 36, alignment: .trailing)
                }
            }
            LabeledContent("Zoom duration") {
                HStack {
                    Slider(value: $model.preferences.cycleDuration, in: AppPreferences.durationRange, step: 1)
                    Text("\(Int(model.preferences.cycleDuration)) s").monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
    }

    private func describe(_ progress: IndexProgress) -> String {
        var parts = ["\(progress.completed) of \(progress.total)"]
        if progress.reused > 0 { parts.append("\(progress.reused) already indexed") }
        if progress.skipped > 0 { parts.append("\(progress.skipped) unreadable") }
        if progress.unavailable > 0 { parts.append("\(progress.unavailable) only in iCloud") }
        return parts.joined(separator: " · ")
    }
}
