import Foundation

/// A semantic version such as "1.2.0" or "1.3.0-beta.1", ordered by SemVer 2.0
/// precedence. A leading "v" and build metadata ("+...") are accepted and
/// ignored for ordering.
public struct FirmwareVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [String]

    public init?(_ text: String) {
        var core = text.trimmingCharacters(in: .whitespaces)
        if core.hasPrefix("v") || core.hasPrefix("V") { core.removeFirst() }
        if let plus = core.firstIndex(of: "+") { core = String(core[..<plus]) }
        var pre: [String] = []
        if let dash = core.firstIndex(of: "-") {
            pre = core[core.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard pre.allSatisfy(Self.isIdentifier) else { return nil }
            core = String(core[..<dash])
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts.allSatisfy(Self.isNumber),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2])
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        prerelease = pre
    }

    /// Digits only, no leading zero (SemVer numeric identifier).
    static func isNumber(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy(\.isASCIIDigit) && (text == "0" || !text.hasPrefix("0"))
    }

    static func isIdentifier(_ text: String) -> Bool {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCIIDigit || $0.isASCIILetter || $0 == "-" }) else { return false }
        return !text.allSatisfy(\.isASCIIDigit) || isNumber(text)
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    public static func < (lhs: FirmwareVersion, rhs: FirmwareVersion) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        // A release ranks above its pre-releases.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, _): return false
        case (false, true): return true
        default: break
        }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            switch (isNumber(a), isNumber(b)) {
            case (true, true): return (a.count, a) < (b.count, b)  // Numeric, without overflow.
            case (true, false): return true  // Numeric identifiers rank below alphanumeric ones.
            case (false, true): return false
            case (false, false): return a < b
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

/// How an offered firmware relates to what the board runs.
public enum FirmwareComparison: Sendable, Equatable {
    case newer
    case same
    case older
    /// One of the versions is not a semantic version.
    case unknown

    public init(offered: String, installed: String) {
        guard let offered = FirmwareVersion(offered), let installed = FirmwareVersion(installed) else {
            self = offered == installed ? .same : .unknown
            return
        }
        self = offered > installed ? .newer : offered == installed ? .same : .older
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIILetter: Bool { isASCII && isLetter }
}
