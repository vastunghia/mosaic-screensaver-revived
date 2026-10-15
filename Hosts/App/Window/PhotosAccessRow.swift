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
                Text("Mosaic Companion needs to read your photo library.")
                Spacer()
                Button("Allow Access…", action: model.requestAccess)
            }
        case .authorized:
            LabeledContent("Using", value: model.albumSummary)
        case .limited:
            HStack {
                Label("Limited to the photographs you picked", systemImage: "circle.lefthalf.filled")
                Spacer()
                Button("Change…", action: model.openPrivacySettings)
            }
        case .denied, .restricted:
            VStack(alignment: .leading) {
                HStack {
                    Label(model.access == .denied ? "Access was refused." : "Access is restricted on this Mac.",
                          systemImage: "xmark.circle")
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
