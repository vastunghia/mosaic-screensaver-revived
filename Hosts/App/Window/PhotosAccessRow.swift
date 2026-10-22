import MosaicPhotoKit
import SwiftUI

/// The Photos permission, and what to do about it.
struct PhotosAccessRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let reason = model.pendingSaverRequest, !model.access.isGranted {
            Label {
                Text("The screen saver asked for photographs (\(reason)).",
                     comment: "The reason in parentheses is a code the screen saver sends, such as no-index")
            } icon: {
                Image(systemName: "info.circle")
            }
                .foregroundStyle(.secondary)
        }
        switch model.access {
        case .notDetermined:
            HStack {
                Text("Mosaic Companion needs to read your photo library.")
                Spacer()
                Button("Allow Access…", action: model.requestAccess)
            }
        case .authorized:
            AlbumsRow(model: model)
        case .limited:
            HStack {
                Label("Limited to the photographs you picked", systemImage: "circle.lefthalf.filled")
                Spacer()
                Button("Change…", action: model.openPrivacySettings)
            }
        case .denied, .restricted:
            VStack(alignment: .leading) {
                HStack {
                    if model.access == .denied {
                        Label("Access was refused.", systemImage: "xmark.circle")
                    } else {
                        Label("Access is restricted on this Mac.", systemImage: "xmark.circle")
                    }
                    Spacer()
                    Button("Open Privacy Settings…", action: model.openPrivacySettings)
                }
                if model.access == .denied {
                    // macOS gives the access to a Mosaic opened afresh, not to
                    // this one: it says so itself, and offers to quit it.
                    HStack {
                        Text("Turn Mosaic Companion on under Photos, then reopen it: the access starts with the next launch. A folder of photographs works too.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reopen Mosaic Companion", action: model.reopen)
                    }
                }
            }
        }
    }
}
