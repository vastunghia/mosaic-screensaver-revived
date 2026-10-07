import SwiftUI

/// Only for a download opened where it was unpacked: everything else works
/// from there, but nothing that has to find the app again later does.
struct LocationStep: View {
    @ObservedObject var model: AppModel
    let number: Int

    var body: some View {
        Section {
            HStack {
                Text("Mosaic is running from where it was downloaded.")
                Spacer()
                Button("Move to Applications", action: model.moveToApplications)
            }
        } header: {
            StepHeader(number: number, title: "Applications", isDone: false)
        } footer: {
            Footnote("It opens again from there. The screen saver and the login item need it to stay in one place; the downloaded copy can then go in the Bin.")
        }
    }
}
