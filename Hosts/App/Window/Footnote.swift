import SwiftUI

/// A section's footer. A grouped form aligns footers to the trailing edge,
/// which leaves a sentence that wraps ragged on the left.
struct Footnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
