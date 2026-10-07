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
                    Text(model.albumSummary)
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
            Picker("How many", selection: $model.preferences.subsetSize) {
                ForEach(sizes, id: \.self) { size in
                    Text(size.formatted()).tag(size)
                }
            }
            Toggle("Download photographs kept only in iCloud", isOn: $model.preferences.allowsDownloads)
        } header: {
            Text("Photographs to Use")
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

    /// Powers of two from 512: more than 8,192 adds time and disk, not
    /// variety. A size chosen before these existed stays on the list.
    private var sizes: [Int] {
        let presets = [512, 1_024, 2_048, 4_096, 8_192]
        let current = model.preferences.subsetSize
        return presets.contains(current) ? presets : (presets + [current]).sorted()
    }
}
