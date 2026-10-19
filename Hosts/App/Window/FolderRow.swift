import SwiftUI

/// The folder the photographs come from, when it is not the Photos library.
struct FolderRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack {
            Group {
                if let folder = model.preferences.folder {
                    Text(verbatim: folder.path)
                } else {
                    Text("None chosen", comment: "No folder of photographs chosen yet")
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(model.preferences.folder == nil ? .secondary : .primary)
            Spacer()
            Button("Choose…", action: model.chooseFolder)
        }
    }
}
