import MosaicPhotoKit
import MosaicPhotos
import SwiftUI

/// Which photographs of the library: albums, how they are picked, how many.
struct LibraryOptions: View {
    @ObservedObject var model: AppModel
    @State private var choosingAlbums = false

    var body: some View {
        Section {
            HStack {
                LabeledContent("Albums") {
                    Text(albumSummary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Button("Choose…", action: chooseAlbums)
                    .disabled(model.albums.isEmpty)
            }
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
            Toggle("Download photographs kept only in iCloud", isOn: $model.preferences.allowsDownloads)
        } header: {
            Text("Photographs to use")
        } footer: {
            Footnote("No album chosen is the whole library; several are combined.")
        }
        .sheet(isPresented: $choosingAlbums) {
            AlbumPicker(model: model)
        }
    }

    private func chooseAlbums() {
        choosingAlbums = true
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
}
