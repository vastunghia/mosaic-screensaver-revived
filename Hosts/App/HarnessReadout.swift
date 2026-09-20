import Foundation
import MosaicEngine

/// What the overlay shows. Separate from the clock because it is written by the
/// display link and read by SwiftUI, a few times a second rather than every
/// frame.
@MainActor
final class HarnessReadout: ObservableObject {
    @Published private(set) var framesPerSecond: Double = 0
    @Published private(set) var statistics = FrameStatistics()

    func publish(framesPerSecond: Double, statistics: FrameStatistics) {
        self.framesPerSecond = framesPerSecond
        self.statistics = statistics
    }
}
