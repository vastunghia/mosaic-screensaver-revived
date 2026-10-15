import SwiftUI

/// Where the photographs come from: chosen in the setup, changed here.
struct SourceOptions: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section("Source") {
            Picker("Photographs from", selection: $model.preferences.source) {
                Text("Photos library").tag(AppPreferences.Source.photos)
                Text("A folder").tag(AppPreferences.Source.folder)
            }
            if model.preferences.source == .folder {
                FolderRow(model: model)
            } else if !model.access.isGranted {
                PhotosAccessRow(model: model)
            }
            ProblemRow(model: model, place: .photographs)
        }
    }
}
