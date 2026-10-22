import SwiftUI

/// The albums in use, and the button that changes them: in Settings, and in
/// the setup, where the warning beside it suggests choosing some.
struct AlbumsRow: View {
    @ObservedObject var model: AppModel
    @State private var choosingAlbums = false

    var body: some View {
        HStack {
            LabeledContent("Albums") {
                Text(model.albumSummary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Button("Choose…") { choosingAlbums = true }
                .disabled(model.albums.isEmpty)
        }
        .sheet(isPresented: $choosingAlbums) {
            AlbumPicker(model: model)
        }
    }
}
