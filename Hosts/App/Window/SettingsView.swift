import SwiftUI

/// Mosaic Companion Settings: what people change seldom, out of the window.
///
/// As tall as its content, up to `heightLimit.points`; past that the form
/// scrolls, so that a short screen (a 13-inch laptop at its default scaling)
/// never hides the last sections below its edge.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var heightLimit: SettingsHeightLimit

    var body: some View {
        CappedHeight(limit: heightLimit.points) {
            Form {
                SourceOptions(model: model)
                if model.preferences.source == .photos, model.access.isGranted {
                    LibraryOptions(model: model)
                    DownloadOptions(model: model)
                }
                MosaicOptions(model: model)
                UpdatesOptions(model: model)
            }
            .formStyle(.grouped)
            // The window's one help button, in its lower trailing corner (HIG,
            // "Help buttons"): the guide's page on these settings.
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()
                    HelpLink { MosaicApplication.showHelp(anchor: "settings") }
                }
                .padding([.horizontal, .bottom])
            }
        }
        .frame(width: 480)
    }
}

/// The tallest the Settings content may be, in points: what the screen leaves
/// below the menu bar, less the title bar. Set by the window's owner, which
/// follows the window from screen to screen.
@MainActor
final class SettingsHeightLimit: ObservableObject {
    @Published var points: CGFloat = .infinity
}

/// Its content at its ideal height, but no taller than `limit`. Proposing the
/// smaller height, rather than clipping the ideal one, is what makes a form
/// scroll instead of overflowing.
private struct CappedHeight: Layout {
    var limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: ideal.width, height: min(ideal.height, limit))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}
