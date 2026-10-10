import SwiftUI

/// Mosaic Settings: what people change seldom, out of the way of the steps.
struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            SourceOptions(model: model)
            if model.preferences.source == .photos, model.access.isGranted {
                LibraryOptions(model: model)
            }
            MosaicOptions(model: model)
            LoginItemOption(model: model)
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
