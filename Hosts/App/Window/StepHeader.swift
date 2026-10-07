import SwiftUI

/// The header of one step of the window: its number until it is done, then a
/// check mark.
struct StepHeader: View {
    let number: Int
    let title: String
    let isDone: Bool

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: isDone ? "checkmark.circle.fill" : "\(number).circle")
                .foregroundStyle(isDone ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(number): \(title)")
        .accessibilityValue(isDone ? "Done" : "To do")
    }
}
