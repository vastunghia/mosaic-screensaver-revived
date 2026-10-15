import SwiftUI

/// Mosaic Companion Settings: what people change seldom, out of the window.
struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            SourceOptions(model: model)
            if model.preferences.source == .photos, model.access.isGranted {
                LibraryOptions(model: model)
                DownloadOptions(model: model)
            }
            MosaicOptions(model: model)
            UpdatesOptions(model: model)
        }
        .formStyle(.grouped)
        // The window's one help button, in its lower trailing corner (HIG,
        // "Help buttons"): the guide's page on these settings.
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                HelpLink { MosaicApplication.showHelp(anchor: "settings") }
            }
            .padding([.horizontal, .bottom])
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
