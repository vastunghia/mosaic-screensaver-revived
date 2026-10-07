import SwiftUI

/// The folder the photographs come from, when it is not the Photos library.
struct FolderRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack {
            Text(model.preferences.folder?.path ?? "None chosen")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(model.preferences.folder == nil ? .secondary : .primary)
            Spacer()
            Button("Choose…", action: model.chooseFolder)
        }
    }
}
