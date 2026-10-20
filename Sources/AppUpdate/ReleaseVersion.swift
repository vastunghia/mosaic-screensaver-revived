import Foundation

/// A version as Mosaic's releases are numbered: numbers separated by dots,
/// tagged with a leading "v" ("v0.4", "0.4.1"), and for a release candidate a
/// suffix of lowercase letters and a number ("v1.0-rc1"). Missing numbers
/// count as zero, so 0.4 and 0.4.0 are the same version; a candidate comes
/// before the version it leads to, so 1.0-rc1 < 1.0-rc2 < 1.0.
public struct ReleaseVersion: Comparable, CustomStringConvertible, Sendable {
    public let components: [Int]
    /// "rc" in 1.0-rc2; nil for a final version.
    public let stage: String?
    /// 2 in 1.0-rc2; 0 for a final version.
    public let stageNumber: Int

    public var isPrerelease: Bool { stage != nil }

    public init?(_ text: String) {
        var text = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.first == "v" { text = text.dropFirst() }

        var stage: String?
        var stageNumber = 0
        if let dash = text.firstIndex(of: "-") {
            let suffix = text[text.index(after: dash)...]
            let letters = suffix.prefix { $0.isASCII && $0.isLowercase }
            let digits = suffix.dropFirst(letters.count)
            guard !letters.isEmpty, !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(digits)
            else { return nil }
            stage = String(letters)
            stageNumber = number
            text = text[..<dash]
        }

        var components: [Int] = []
        for part in text.split(separator: ".", omittingEmptySubsequences: false) {
            // Not Int(_:) alone, which takes "+1".
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(part)
            else { return nil }
            components.append(number)
        }
        guard !components.isEmpty else { return nil }
        self.components = components
        self.stage = stage
        self.stageNumber = stageNumber
    }

    public var description: String {
        let numbers = components.map(String.init).joined(separator: ".")
        return stage.map { "\(numbers)-\($0)\(stageNumber)" } ?? numbers
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
        switch (a.stage, b.stage) {
        case (nil, nil): return 0
        case (nil, _): return 1
        case (_, nil): return -1
        case let (x?, y?):
            if x != y { return x < y ? -1 : 1 }
            return a.stageNumber == b.stageNumber ? 0 : (a.stageNumber < b.stageNumber ? -1 : 1)
        }
    }
}
