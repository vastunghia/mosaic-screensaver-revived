import Foundation
import Network

/// Whether the network costs the user something: a hotspot (expensive) or
/// Low Data Mode (constrained). Close-ups are not fetched over either, even
/// when the user allowed it (SPEC § 5): the allowance was for their disk,
/// not for a phone's data plan.
enum NetworkCost {
    /// Blocks until the system describes the current path, at most `timeout`;
    /// not knowing counts as metered.
    static func isMetered(timeout: TimeInterval = 2) -> Bool {
        let monitor = NWPathMonitor()
        let answer = Answer()
        let done = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { path in
            answer.set(path.isExpensive || path.isConstrained)
            done.signal()
        }
        monitor.start(queue: DispatchQueue(label: "mosaic.network-cost"))
        defer { monitor.cancel() }
        guard done.wait(timeout: .now() + timeout) == .success else { return true }
        return answer.value ?? true
    }

    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var metered: Bool?

        func set(_ value: Bool) {
            lock.lock()
            if metered == nil { metered = value }
            lock.unlock()
        }

        var value: Bool? {
            lock.lock(); defer { lock.unlock() }
            return metered
        }
    }
}
