import SwiftUI

/// Where the photographs come from, and the permission to read them.
struct PhotographsStep: View {
    @ObservedObject var model: AppModel
    let number: Int

    var body: some View {
        Section {
            Picker("Photographs from", selection: $model.preferences.source) {
                Text("Photos library").tag(AppPreferences.Source.photos)
                Text("A folder").tag(AppPreferences.Source.folder)
            }
            .pickerStyle(.segmented)
            if model.preferences.source == .photos {
                PhotosAccessRow(model: model)
            } else {
                FolderRow(model: model)
            }
        } header: {
            StepHeader(number: number, title: "Photographs", isDone: model.hasPhotographs)
        } footer: {
            Footnote("They never leave this Mac: Mosaic keeps a small copy of each, to build the mosaics from.")
        }
    }
}
