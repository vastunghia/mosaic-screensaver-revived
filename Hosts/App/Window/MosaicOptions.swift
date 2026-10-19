import SwiftUI

/// The two settings the original exposed: rows, and how long a zoom lasts.
struct MosaicOptions: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section("Mosaic") {
            LabeledContent("Rows") {
                HStack {
                    Slider(
                        value: $model.preferences.rowsForSlider,
                        in: Double(AppPreferences.rowRange.lowerBound)...Double(AppPreferences.rowRange.upperBound),
                        step: 1
                    )
                    Text(model.preferences.rows, format: .number)
                        .monospacedDigit()
                        .frame(minWidth: 36, alignment: .trailing)
                }
            }
            LabeledContent("Zoom duration") {
                HStack {
                    Slider(value: $model.preferences.cycleDuration, in: AppPreferences.durationRange, step: 1)
                    Text("\(Int(model.preferences.cycleDuration)) s", comment: "Zoom duration in seconds, beside its slider")
                        .monospacedDigit()
                        .frame(minWidth: 36, alignment: .trailing)
                }
            }
        }
    }
}
