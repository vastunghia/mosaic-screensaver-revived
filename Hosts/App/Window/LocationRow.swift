import SwiftUI

/// Only for a download opened where it was unpacked: everything else works
/// from there, but nothing that has to find the app again later does.
struct LocationRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack {
            Text("Mosaic Companion is running from where it was downloaded.")
            Spacer()
            Button("Move to Applications", action: model.moveToApplications)
        }
    }
}
