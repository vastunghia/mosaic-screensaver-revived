import SwiftUI

/// The warning the README gives too: the screen saver shows the whole library
/// to whoever passes by. Under the choice that leads to it, in the setup and
/// in Settings, as a footnote with a sign that sets it apart from the others.
struct PrivacyNote: View {
    let text: Text

    init(_ key: LocalizedStringKey) {
        text = Text(key)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Footnote(text)
        }
    }
}
