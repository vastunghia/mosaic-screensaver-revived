import SwiftUI

/// A section's footer. A grouped form aligns footers to the trailing edge,
/// which leaves a sentence that wraps ragged on the left.
///
/// Like `Text`, a literal is a key in the String Catalog, and a `String` is
/// shown as it is: already localized by whoever made it. A key that needs a
/// comment for its translator comes as a `Text`, which carries one.
struct Footnote: View {
    let text: Text

    init(_ key: LocalizedStringKey) {
        text = Text(key)
    }

    /// Disfavoured, as `Text`'s own: otherwise a literal would pick it over
    /// the key, and go untranslated.
    @_disfavoredOverload
    init<S: StringProtocol>(_ content: S) {
        text = Text(content)
    }

    init(_ text: Text) {
        self.text = text
    }

    var body: some View {
        text
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
