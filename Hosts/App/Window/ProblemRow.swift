import SwiftUI

/// The problem that belongs to one place of the window, if there is one.
struct ProblemRow: View {
    @ObservedObject var model: AppModel
    let place: Problem.Place

    var body: some View {
        if let problem = model.problem, problem.place == place {
            Label {
                Text(problem.message)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }
}
