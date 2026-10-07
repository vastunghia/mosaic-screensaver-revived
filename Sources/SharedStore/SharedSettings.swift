import Foundation

/// M11: the settings the app chooses and the .saver uses.
///
/// Settings live only in the app (milestone 5): the saver has no preferences of
/// its own, and its options sheet only points at the app. The app writes this
/// file next to the index whenever they change; the saver reads it once per
/// run, as it does the index. Only what the effect needs travels: `R` and `T`,
/// the two knobs the original exposed.
public struct SharedSettings: Codable, Equatable, Sendable {
    /// `R`: rows, columns and the zoom factor (SPEC § 4).
    public var rows: Int
    /// `T`: seconds per cycle.
    public var cycleDuration: Double

    /// The ranges the app offers. The saver clamps to them too, so a file
    /// written by another version, or by hand, cannot ask for anything else.
    public static let rowRange = 60...120
    public static let durationRange: ClosedRange<Double> = 10...60

    public static let standard = SharedSettings(rows: 90, cycleDuration: 25)

    public init(rows: Int, cycleDuration: Double) {
        self.rows = min(max(rows, Self.rowRange.lowerBound), Self.rowRange.upperBound)
        self.cycleDuration = cycleDuration.isFinite
            ? min(max(cycleDuration, Self.durationRange.lowerBound), Self.durationRange.upperBound)
            : Self.standard.cycleDuration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            rows: try container.decode(Int.self, forKey: .rows),
            cycleDuration: try container.decode(Double.self, forKey: .cycleDuration)
        )
    }

    /// Nil when there is no file yet or it cannot be read: the saver then runs
    /// with the standard settings, never not at all.
    public static func read(from url: URL = SharedLocations.settingsFile) -> SharedSettings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SharedSettings.self, from: data)
    }

    /// Atomic, as everything the saver may be reading while the app writes.
    public func write(to url: URL = SharedLocations.settingsFile) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
