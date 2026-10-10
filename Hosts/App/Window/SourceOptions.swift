import SwiftUI

/// Where the photographs come from, in Settings too: once every step is done
/// the steps fold away, and with them the first step's choice.
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
