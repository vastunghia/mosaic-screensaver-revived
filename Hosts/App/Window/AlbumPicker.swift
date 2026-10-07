import MosaicPhotoKit
import SwiftUI

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
