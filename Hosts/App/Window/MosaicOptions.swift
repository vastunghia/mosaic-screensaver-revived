import SwiftUI

/// The two settings the original exposed: rows, and how long a zoom lasts.
/// Sliders without steps: with one a row or a second apart, their tick marks
/// ran together. The preferences round what they set instead.
struct MosaicOptions: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section("Mosaic") {
            LabeledContent("Rows") {
                HStack {
                    Slider(
                        value: $model.preferences.rowsForSlider,
                        in: Double(AppPreferences.rowRange.lowerBound)...Double(AppPreferences.rowRange.upperBound)
                    )
                    Text(model.preferences.rows, format: .number)
                        .monospacedDigit()
                        .frame(minWidth: 36, alignment: .trailing)
                }
            }
            LabeledContent("Zoom duration") {
                HStack {
                    Slider(value: $model.preferences.durationForSlider, in: AppPreferences.durationRange)
                    Text("\(Int(model.preferences.cycleDuration)) s", comment: "Zoom duration in seconds, beside its slider")
                        .monospacedDigit()
                        .frame(minWidth: 36, alignment: .trailing)
                }
            }
        }
    }
}
