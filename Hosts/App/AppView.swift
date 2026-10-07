import MosaicPhotoKit
import MosaicPhotos
import PhotoIndex
import SwiftUI

/// The app's one window: where the photographs come from, the index, the two
/// settings the original exposed, and Play.
struct AppView: View {
    @ObservedObject var model: AppModel
    let play: () -> Void
    @State private var choosingAlbums = false

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
                screenSaverSection
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
            model.refreshLoginItem()
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
                HStack {
                    Text(albumSummary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Button("Choose…") { choosingAlbums = true }
                        .disabled(model.albums.isEmpty)
                }
            } header: {
                Text("Albums")
            } footer: {
                Text("None chosen is the whole library; several are combined.")
            }
            .sheet(isPresented: $choosingAlbums) {
                AlbumPicker(model: model)
            }
        }
    }

    /// One line, however many albums there are: the list itself lives in a
    /// sheet. Laid out inline, a Form built one view per album at once, and on
    /// a library with many albums that held the main thread — and the effect
    /// drawn on it — for over ten seconds.
    private var albumSummary: String {
        let chosen = model.preferences.albumIdentifiers
        if chosen.isEmpty { return "All photographs" }
        let titles = model.albums.filter { chosen.contains($0.id) }.map(\.title)
        if titles.isEmpty { return chosen.count == 1 ? "1 album" : "\(chosen.count) albums" }
        return titles.joined(separator: ", ")
    }

    @ViewBuilder
    private var accessRow: some View {
        if let reason = model.pendingSaverRequest, !model.access.isGranted {
            Label("The screen saver asked for photographs (\(reason)).", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        }
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

    /// Whether the app keeps the index fresh on its own. The system's word is
    /// the truth: the user can switch it off in System Settings.
    private var screenSaverSection: some View {
        Section {
            Toggle("Open at login to keep the screen saver's photographs up to date", isOn: Binding(
                get: { model.opensAtLogin },
                set: { model.setOpensAtLogin($0) }
            ))
            if model.loginItem == .requiresApproval {
                HStack {
                    Text("Waiting for approval in System Settings.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Login Items…") { model.openLoginItemsSettings() }
                }
            }
        } header: {
            Text("Screen Saver")
        } footer: {
            Text("Mosaic then runs without a window, and the screen saver always has the latest photographs.")
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

/// The albums to draw the photographs from, in a sheet.
///
/// A `List`, which on macOS is a table view and makes rows only for what is on
/// screen, so a library with thousands of albums costs no more than one with
/// ten. The choice is applied on Done, not on every click: each change of
/// scope restarts the index.
struct AlbumPicker: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String> = []
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding()
            List(shown) { album in
                Toggle(isOn: Binding(
                    get: { chosen.contains(album.id) },
                    set: { if $0 { chosen.insert(album.id) } else { chosen.remove(album.id) } }
                )) {
                    HStack {
                        Text(album.title)
                        Spacer()
                        Text("\(album.count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .toggleStyle(.checkbox)
            }
            HStack {
                Text(chosen.isEmpty ? "All photographs" : chosen.count == 1 ? "1 album" : "\(chosen.count) albums")
                    .foregroundStyle(.secondary)
                Button("Clear") { chosen = [] }
                    .disabled(chosen.isEmpty)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    // In the order the albums are listed, so an unchanged choice
                    // compares equal and does not restart the index.
                    let ordered = model.albums.map(\.id).filter(chosen.contains)
                    if Set(ordered) != Set(model.preferences.albumIdentifiers) {
                        model.preferences.albumIdentifiers = ordered
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 420, height: 520)
        .onAppear { chosen = Set(model.preferences.albumIdentifiers) }
    }

    private var shown: [PhotoLibraryAccess.Album] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.albums }
        return model.albums.filter { $0.title.localizedStandardContains(query) }
    }
}
