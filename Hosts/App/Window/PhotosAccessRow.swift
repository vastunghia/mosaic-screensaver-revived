import MosaicPhotoKit
import SwiftUI

/// The Photos permission, and what to do about it.
struct PhotosAccessRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let reason = model.pendingSaverRequest, !model.access.isGranted {
            Label("The screen saver asked for photographs (\(reason)).", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        }
        switch model.access {
        case .notDetermined:
            HStack {
                Text("Mosaic needs to read your photo library.")
                Spacer()
                Button("Allow Access…", action: model.requestAccess)
            }
        case .authorized:
            Label("Access granted", systemImage: "checkmark.circle")
        case .limited:
            HStack {
                Label("Limited to the photographs you picked", systemImage: "circle.lefthalf.filled")
                Spacer()
                Button("Change…", action: model.openPrivacySettings)
            }
        case .denied, .restricted:
            VStack(alignment: .leading) {
                HStack {
                    Label(model.access == .denied ? "Access was refused" : "Access is restricted on this Mac",
                          systemImage: "xmark.circle")
                    Spacer()
                    Button("Open System Settings…", action: model.openPrivacySettings)
                }
                if model.access == .denied {
                    Text("Turn Mosaic on under Photos, then come back here. A folder of photographs works too.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
