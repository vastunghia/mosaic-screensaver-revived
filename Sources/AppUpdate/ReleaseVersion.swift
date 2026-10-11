import Foundation

/// A version as Mosaic's releases are numbered: numbers separated by dots,
/// tagged with a leading "v" ("v0.4", "0.4.1"). Missing numbers count as
/// zero, so 0.4 and 0.4.0 are the same version.
public struct ReleaseVersion: Comparable, CustomStringConvertible, Sendable {
    public let components: [Int]

    public init?(_ text: String) {
        var text = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.first == "v" { text = text.dropFirst() }
        var components: [Int] = []
        for part in text.split(separator: ".", omittingEmptySubsequences: false) {
            // Not Int(_:) alone, which takes "+1".
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(part)
            else { return nil }
            components.append(number)
        }
        guard !components.isEmpty else { return nil }
        self.components = components
    }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }

    public static func == (a: ReleaseVersion, b: ReleaseVersion) -> Bool {
        compare(a, b) == 0
    }

    public static func < (a: ReleaseVersion, b: ReleaseVersion) -> Bool {
        compare(a, b) < 0
    }

    private static func compare(_ a: ReleaseVersion, _ b: ReleaseVersion) -> Int {
        for index in 0..<max(a.components.count, b.components.count) {
            let x = index < a.components.count ? a.components[index] : 0
            let y = index < b.components.count ? b.components[index] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}
