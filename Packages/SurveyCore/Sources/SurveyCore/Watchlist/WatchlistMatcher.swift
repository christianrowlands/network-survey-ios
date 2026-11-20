import Foundation

/// The watchlist's matching and normalization rules, shared by detection
/// during a survey, the watched marker in lists and details, adding, editing
/// and importing, so they can never drift apart. They follow the Network
/// Survey Android app:
///
/// - Values are trimmed and compared without regard to case.
/// - An entry with both an SSID and a BSSID matches only when both match.
///   With one of them, that one alone decides.
/// - An empty network name (a hidden network) never matches an SSID.
public enum WatchlistMatcher {
    /// True when the network `ssid`/`bssid` satisfies the entry's match rule.
    public static func matches(_ entry: WatchlistEntry, ssid: String?, bssid: String?) -> Bool {
        matches(entrySSID: entry.ssid, entryBSSID: entry.bssid, ssid: ssid, bssid: bssid)
    }

    public static func matches(entrySSID: String?, entryBSSID: String?, ssid: String?, bssid: String?) -> Bool {
        let wantedSSID = normalizeSSID(entrySSID)
        let wantedBSSID = trimmed(entryBSSID)
        if wantedSSID == nil && wantedBSSID == nil { return false }
        let seenSSID = trimmed(ssid)
        let seenBSSID = trimmed(bssid)
        let ssidMatches = wantedSSID.map { wanted in seenSSID.map { equalIgnoringCase($0, wanted) } ?? false } ?? false
        let bssidMatches = wantedBSSID.map { wanted in seenBSSID.map { equalIgnoringCase($0, wanted) } ?? false } ?? false
        switch (wantedSSID, wantedBSSID) {
        case (.some, .some): return ssidMatches && bssidMatches
        case (.some, nil): return ssidMatches
        default: return bssidMatches
        }
    }

    // MARK: - Normalization

    /// Trimmed, case preserved; nil when blank.
    public static func normalizeSSID(_ ssid: String?) -> String? {
        trimmed(ssid)
    }

    /// Trimmed and lowercase; nil when blank. Does not check the format.
    public static func normalizeBSSID(_ bssid: String?) -> String? {
        trimmed(bssid)?.lowercased()
    }

    /// `XX:XX:XX:XX:XX:XX` in hex digits of either case, the only form a
    /// share link may carry.
    public static func isValidBSSID(_ text: String) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 6 && parts.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isHexDigit) }
    }

    /// A BSSID typed by hand: 12 hex digits with colons, dashes, dots or
    /// nothing between them, as lowercase `xx:xx:xx:xx:xx:xx`. Nil otherwise.
    public static func parseBSSID(_ text: String) -> String? {
        guard let hex = MACAddress.normalizedHex(text.trimmingCharacters(in: .whitespacesAndNewlines)), hex.count == 12
        else { return nil }
        let pairs = stride(from: 0, to: 12, by: 2).map { offset -> String in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return String(hex[start..<hex.index(start, offsetBy: 2)])
        }
        return pairs.joined(separator: ":").lowercased()
    }

    /// The display name: the label, else the SSID, else the BSSID.
    public static func resolveLabel(_ label: String?, ssid: String?, bssid: String?) -> String {
        trimmed(label) ?? normalizeSSID(ssid) ?? normalizeBSSID(bssid) ?? ""
    }

    /// Two entries are the same network when both their SSIDs (ignoring case)
    /// and their BSSIDs match; a missing field matches only a missing field.
    public static func dedupKey(ssid: String?, bssid: String?) -> String {
        let ssidKey = normalizeSSID(ssid)?.lowercased() ?? ""
        return "\(ssidKey.count):\(ssidKey):\(normalizeBSSID(bssid) ?? "")"
    }

    // MARK: - Private

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func equalIgnoringCase(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: .caseInsensitive) == .orderedSame
    }
}

/// Bounds on watchlist values, the same as the Network Survey Android app's
/// share link checks.
public enum WatchlistLimits {
    /// The 802.11 limit.
    public static let maxSSIDLength = 32
    public static let maxLabelLength = 100
    public static let maxListNameLength = 100
    /// Networks in one share link.
    public static let maxEntries = 100
    /// Characters in a share link's encoded `d` value.
    public static let maxEncodedLength = 16 * 1024
}
