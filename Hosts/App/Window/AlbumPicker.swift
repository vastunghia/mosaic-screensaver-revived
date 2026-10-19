import MosaicPhotoKit
import SwiftUI

/// The albums to draw the photographs from, in a sheet, in the folders Photos
/// shows them in.
///
/// A `List`, which on macOS is a table view (an outline view, with folders)
/// and makes rows only for what is on screen, so a library with thousands of
/// albums costs no more than one with ten. The choice is applied on Done, not
/// on every click: each change of scope restarts the index.
struct AlbumPicker: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String> = []
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            SearchField(prompt: "Search Albums", text: $filter)
                .padding()
            if query.isEmpty {
                List(model.albums.roots, children: \.children) { node in
                    row(node)
                }
            } else {
                List(model.albums.search(query)) { match in
                    VStack(alignment: .leading, spacing: 2) {
                        row(match.node)
                        if !match.path.isEmpty {
                            Text(match.path.joined(separator: " › "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 20)
                        }
                    }
                }
            }
            Footnote("Photographs only. A folder's count adds up its albums, so a photograph in more than one counts more than once.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding([.horizontal, .top])
            HStack {
                Text(summary)
                    .foregroundStyle(.secondary)
                Button("Clear") { chosen = [] }
                    .disabled(chosen.isEmpty)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    // In the order the sidebar lists them, so an unchanged
                    // choice compares equal and does not restart the index.
                    let ordered = model.albums.ordered(chosen)
                    if Set(ordered) != Set(model.preferences.collectionIdentifiers) {
                        model.preferences.collectionIdentifiers = ordered
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 460, height: 560)
        .onAppear { chosen = Set(model.preferences.collectionIdentifiers) }
    }

    private func row(_ node: AlbumTree.Node) -> some View {
        let state = model.albums.state(of: node.id, in: chosen)
        // A checkbox shows a mixed state only when its sources disagree.
        let values = state == .mixed ? [true, false] : [state == .on]
        let sources = values.indices.map { index in
            Binding(get: { values[index] }, set: { set(node.id, on: $0) })
        }
        return Toggle(sources: sources, isOn: \.self) {
            HStack {
                Label(node.title, systemImage: symbol(for: node.kind))
                Spacer()
                Text(node.count, format: .number).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .toggleStyle(.checkbox)
    }

    /// Called once per source, so it only acts when the state has to change.
    private func set(_ id: String, on: Bool) {
        let isOn = model.albums.state(of: id, in: chosen) == .on
        guard on != isOn else { return }
        chosen = model.albums.toggling(id, in: chosen)
    }

    private func symbol(for kind: AlbumTree.Kind) -> String {
        switch kind {
        case .favorites: "heart"
        case .folder: "folder"
        case .album: "rectangle.stack"
        }
    }

    private var query: String {
        filter.trimmingCharacters(in: .whitespaces)
    }

    private var summary: String {
        guard !chosen.isEmpty else {
            return String(localized: "All photographs", comment: "Albums in use: none chosen, so the whole library")
        }
        let folders = chosen.filter { model.albums.node($0)?.kind == .folder }.count
        let albums = chosen.count - folders
        return [
            albums > 0 ? String(localized: "\(albums) albums", comment: "A number of albums, in a summary of those chosen") : nil,
            folders > 0 ? String(localized: "\(folders) folders", comment: "A number of folders of albums, in a summary of those chosen") : nil,
        ].compactMap { $0 }.joined(separator: ", ")
    }
}
