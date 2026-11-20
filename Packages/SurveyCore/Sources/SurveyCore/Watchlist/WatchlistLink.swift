import Foundation
import NSMessaging

/// A network from a share link, already checked and normalized.
public struct WatchlistImportEntry: Sendable, Equatable {
    public var label: String?
    public var ssid: String?
    /// Lowercase.
    public var bssid: String?

    public init(label: String?, ssid: String?, bssid: String?) {
        self.label = label
        self.ssid = ssid
        self.bssid = bssid
    }
}

/// The networks a share link carries, and the list's name (only for the prompt).
public struct WatchlistImportSet: Sendable, Equatable {
    public var name: String?
    public var entries: [WatchlistImportEntry]
}

/// Why a share link was refused. Nothing is imported then.
public enum WatchlistLinkError: Error, Equatable, Sendable {
    case noData, tooLarge, unreadable, newerVersion, noNetworks, noValidNetworks, tooMany
    case invalidBSSID, ssidTooLong, labelTooLong, nameTooLong

    public var message: String {
        switch self {
        case .noData: "This link has no watchlist data."
        case .tooLarge: "This watchlist link is too large."
        case .unreadable: "This watchlist link can't be read."
        case .newerVersion: "This watchlist link needs a newer version of the app."
        case .noNetworks: "This link has no networks."
        case .noValidNetworks: "This link has no valid networks."
        case .tooMany: "This link has too many networks. A link holds at most \(WatchlistLimits.maxEntries)."
        case .invalidBSSID: "This link has an invalid BSSID."
        case .ssidTooLong: "This link has an SSID that is too long."
        case .labelTooLong: "This link has a label that is too long."
        case .nameTooLong: "This link has a list name that is too long."
        }
    }
}

/// Watchlist share links, the same as the Network Survey Android app's:
/// `https://networksurvey.app/app/watchlist?d=<payload>`, where the payload is
/// UTF-8 JSON in base64url without padding:
///
///     {"v":1,"name":"Acme networks","entries":[{"label":"HQ","ssid":"HQ-Guest"},{"bssid":"a4:11:22:33:44:1c"}]}
///
/// A link comes from someone else, so every value is bounded and cleaned
/// before it reaches the screen or the database, and a link with anything out
/// of bounds is refused whole (never cut short). Only an entry with neither an
/// SSID nor a BSSID is skipped. The rules match Android's
/// `WatchlistDeepLinkHandler` and the format page on networksurvey.app.
public enum WatchlistLink {
    public static let host = "networksurvey.app"
    public static let path = "/app/watchlist"
    public static let dataParameter = "d"
    public static let version = 1

    /// True for a link to the watchlist import page, valid or not.
    public static func isWatchlistLink(_ url: URL) -> Bool {
        url.host()?.lowercased() == host && url.path().hasPrefix(path)
    }

    /// The first watchlist link in pasted text (a message with a link in it,
    /// or the link alone).
    public static func find(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        let links = detector?.matches(in: text, range: range).compactMap(\.url) ?? []
        return links.first(where: isWatchlistLink)
    }

    public static func parse(_ url: URL) throws(WatchlistLinkError) -> WatchlistImportSet {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let encoded = items.first { $0.name == dataParameter }?.value ?? ""
        return try parse(encoded: encoded)
    }

    /// Checks the `d` value of a link.
    public static func parse(encoded: String) throws(WatchlistLinkError) -> WatchlistImportSet {
        guard !encoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .noData }
        guard encoded.count <= WatchlistLimits.maxEncodedLength else { throw .tooLarge }
        guard let json = decodeBase64URL(encoded),
              let payload = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        else { throw .unreadable }
        guard let version = payload["v"] as? NSNumber, !isBool(version), version.doubleValue == Double(Self.version)
        else { throw .newerVersion }
        guard let rawEntries = payload["entries"] as? [Any], !rawEntries.isEmpty else { throw .noNetworks }
        guard rawEntries.count <= WatchlistLimits.maxEntries else { throw .tooMany }
        var entries: [WatchlistImportEntry] = []
        for raw in rawEntries {
            guard let object = raw as? [String: Any] else { continue }
            if let entry = try validate(object) { entries.append(entry) }
        }
        guard !entries.isEmpty else { throw .noValidNetworks }
        let name = sanitize(text(payload["name"])).flatMap { $0.isEmpty ? nil : $0 }
        if let name, name.count > WatchlistLimits.maxListNameLength { throw .nameTooLong }
        return WatchlistImportSet(name: name, entries: entries)
    }

    /// A link for these networks. Labels are left out where they are just the
    /// network name or address. Throws when the list is too long for a link.
    public static func makeURL(name: String? = nil, entries: [WatchlistEntry]) throws(WatchlistLinkError) -> URL {
        guard !entries.isEmpty else { throw .noNetworks }
        guard entries.count <= WatchlistLimits.maxEntries else { throw .tooMany }
        var writer = NSJSONWriter()
        writer.beginObject()
        writer.key("v")
        writer.integer(version)
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            writer.key("name")
            writer.string(name)
        }
        writer.key("entries")
        writer.beginArray()
        for entry in entries {
            writer.element()
            writer.beginObject()
            if entry.label != WatchlistMatcher.resolveLabel(nil, ssid: entry.ssid, bssid: entry.bssid) {
                writer.key("label")
                writer.string(entry.label)
            }
            if let ssid = entry.ssid {
                writer.key("ssid")
                writer.string(ssid)
            }
            if let bssid = entry.bssid {
                writer.key("bssid")
                writer.string(bssid)
            }
            writer.endObject()
        }
        writer.endArray()
        writer.endObject()
        let encoded = encodeBase64URL(Data(writer.output.utf8))
        guard encoded.count <= WatchlistLimits.maxEncodedLength else { throw .tooLarge }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = [URLQueryItem(name: dataParameter, value: encoded)]
        guard let url = components.url else { throw .unreadable }
        return url
    }

    // MARK: - Checks

    /// A valid entry, nil for one with nothing to match (skipped), or the
    /// reason the whole link is refused.
    private static func validate(_ object: [String: Any]) throws(WatchlistLinkError) -> WatchlistImportEntry? {
        let ssid = sanitize(text(object["ssid"])).flatMap { $0.isEmpty ? nil : $0 }
        let bssidText = text(object["bssid"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bssid = bssidText.flatMap { $0.isEmpty ? nil : $0 }
        if let bssid, !WatchlistMatcher.isValidBSSID(bssid) { throw .invalidBSSID }
        if ssid == nil && bssid == nil { return nil }
        if let ssid, ssid.count > WatchlistLimits.maxSSIDLength { throw .ssidTooLong }
        let label = sanitize(text(object["label"])).flatMap { $0.isEmpty ? nil : $0 }
        if let label, label.count > WatchlistLimits.maxLabelLength { throw .labelTooLong }
        return WatchlistImportEntry(label: label, ssid: ssid, bssid: bssid?.lowercased())
    }

    /// Strings as they are; numbers as text (as Gson reads them on Android).
    private static func text(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber, !isBool(number) { return number.stringValue }
        return nil
    }

    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// Removes control and invisible formatting characters (zero-width
    /// spaces, direction overrides) that could garble or fake the prompt, then trims.
    static func sanitize(_ value: String?) -> String? {
        guard let value else { return nil }
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format: continue
            default: scalars.append(scalar)
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// base64url only: a value with `+` or `/` is refused, as on Android.
    static func decodeBase64URL(_ text: String) -> Data? {
        var value = text
        while value.hasSuffix("=") { value.removeLast() }
        guard !value.contains("+"), !value.contains("/"), !value.contains("=") else { return nil }
        value = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        if value.count % 4 != 0 { value += String(repeating: "=", count: 4 - value.count % 4) }
        return Data(base64Encoded: value)
    }

    static func encodeBase64URL(_ data: Data) -> String {
        var text = data.base64EncodedString()
        while text.hasSuffix("=") { text.removeLast() }
        return text.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
}
