import Foundation

/// What the IEEE MAC address registries say about an address or prefix.
nonisolated struct OUIMatch: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Registered to this organization.
        case vendor(String)
        /// Registered, but the organization asked IEEE not to publish its name.
        case privateVendor
        /// The 24-bit prefix belongs to IEEE and is split into smaller
        /// MA-M or MA-S blocks; too few digits were given, or none matched.
        case sharedBlock
        /// The locally administered bit is set: a randomized (private)
        /// address or one assigned by software, never in a registry.
        case locallyAdministered
        /// The group bit is set: a multicast or broadcast address.
        case multicast
        case notFound
    }

    /// The IEEE registry a prefix came from, by prefix length.
    enum Registry: String, Sendable {
        case maL = "MA-L"
        case maM = "MA-M"
        case maS = "MA-S"

        var bits: Int {
            switch self {
            case .maL: 24
            case .maM: 28
            case .maS: 36
            }
        }
    }

    var kind: Kind
    /// Set when a registry entry matched.
    var registry: Registry?
    /// The matched prefix, for example "AC:DE:48" or "70:B3:D5:1F:A".
    var prefix: String?

    /// The organization name, only for a published registration.
    var vendor: String? {
        if case .vendor(let name) = kind { name } else { nil }
    }
}

/// Manufacturer names for MAC addresses from the bundled IEEE MA-L, MA-M and
/// MA-S registries (`oui.tsv`, refreshed by scripts/update-oui.sh). Lookups
/// stay on the phone.
nonisolated enum OUIRegistry {
    /// The manufacturer of a globally unique address, or nil when the
    /// address is randomized, multicast, private or not registered.
    static func vendor(for mac: String) -> String? {
        lookup(mac)?.vendor
    }

    /// `vendor(for:)` in its short form, for list rows.
    static func shortVendor(for mac: String) -> String? {
        vendor(for: mac).map(shortName)
    }

    /// A shorter organization name for list rows: legal suffixes such as
    /// "Co., Ltd." and "Inc." dropped, so "HUAWEI TECHNOLOGIES CO.,LTD" reads
    /// "HUAWEI TECHNOLOGIES". Detail screens show the registered name.
    static func shortName(_ name: String) -> String {
        var result = name.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            for suffix in legalSuffixes {
                let lower = result.lowercased()
                guard lower.hasSuffix(suffix), lower.count > suffix.count else { continue }
                let kept = result.dropLast(suffix.count)
                // Only whole words: "Telecom" must not lose "com" or "Co".
                guard let last = kept.last, last == " " || last == "," || last == "." else { continue }
                result = kept.trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
                changed = true
            }
        }
        return result.isEmpty ? name : result
    }

    /// Lower case, longest first so "co., ltd." goes before "ltd.".
    private static let legalSuffixes = [
        "co., ltd.", "co.,ltd.", "co., ltd", "co.,ltd", "co ltd", "corporation", "corporate", "limited",
        "gmbh & co. kg", "gmbh", "corp.", "corp", "inc.", "inc", "ltd.", "ltd", "llc", "l.l.c.", "s.a.", "sas",
        "s.r.l.", "srl", "b.v.", "bv", "ag", "a/s", "ab", "oy", "pty", "pte", "plc", "co.", "co",
    ].sorted { $0.count > $1.count }

    /// Looks up a full address or a prefix of at least 6 hex digits, written
    /// with colons, dashes, dots, spaces or nothing between the digits.
    /// Returns nil when the text is not that.
    static func lookup(_ text: String) -> OUIMatch? {
        guard let digits = hexDigits(text), digits.count >= 6 else { return nil }
        return lookup(digits: digits, in: table)
    }

    /// The hex digits of an address in upper case, at most 12, or nil when
    /// the text has anything other than hex digits and separators.
    static func hexDigits(_ text: String) -> String? {
        var digits = ""
        for character in text {
            if character.isHexDigit {
                digits.append(character.uppercased())
            } else if !":-. ".contains(character) {
                return nil
            }
        }
        return digits.count <= 12 ? digits : nil
    }

    static func lookup(digits: String, in table: Table) -> OUIMatch {
        guard let first = UInt8(digits.prefix(2), radix: 16) else { return OUIMatch(kind: .notFound) }
        if first & 0x01 != 0 { return OUIMatch(kind: .multicast) }
        if first & 0x02 != 0 { return OUIMatch(kind: .locallyAdministered) }
        // The most specific registration wins: an MA-S or MA-M block sits
        // inside an MA-L prefix registered to the IEEE itself.
        for registry in [OUIMatch.Registry.maS, .maM, .maL] {
            let width = registry.bits / 4
            guard digits.count >= width, let key = UInt64(digits.prefix(width), radix: 16),
                  let name = table.names[registry]?[key] else { continue }
            let prefix = format(String(digits.prefix(width)))
            switch name {
            case "IEEE Registration Authority": return OUIMatch(kind: .sharedBlock, registry: registry, prefix: prefix)
            case "Private": return OUIMatch(kind: .privateVendor, registry: registry, prefix: prefix)
            default: return OUIMatch(kind: .vendor(name), registry: registry, prefix: prefix)
            }
        }
        return OUIMatch(kind: .notFound)
    }

    /// "70B3D51FA" as "70:B3:D5:1F:A".
    static func format(_ digits: String) -> String {
        var groups: [Substring] = []
        var rest = Substring(digits)
        while !rest.isEmpty {
            groups.append(rest.prefix(2))
            rest = rest.dropFirst(2)
        }
        return groups.joined(separator: ":")
    }

    /// Prefixes by registry, keyed by the prefix's numeric value.
    struct Table: Sendable {
        var names: [OUIMatch.Registry: [UInt64: String]] = [:]

        var count: Int { names.values.reduce(0) { $0 + $1.count } }

        /// Reads "PREFIX<TAB>Organization" lines; the prefix length (6, 7 or
        /// 9 hex digits) says which registry the line came from.
        static func parse(_ text: String) -> Table {
            var table = Table()
            var interned: [Substring: String] = [:]
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let tab = line.firstIndex(of: "\t") else { continue }
                let prefix = line[..<tab], name = line[line.index(after: tab)...]
                let registry: OUIMatch.Registry
                switch prefix.count {
                case 6: registry = .maL
                case 7: registry = .maM
                case 9: registry = .maS
                default: continue
                }
                guard let key = UInt64(prefix, radix: 16), !name.isEmpty else { continue }
                // Big vendors hold hundreds of prefixes; keep one copy of each name.
                let shared = interned[name] ?? String(name)
                interned[name] = shared
                table.names[registry, default: [:]][key] = shared
            }
            return table
        }
    }

    /// Loaded on first use (about 54,000 prefixes); `warmUp()` does it early.
    static let table: Table = {
        guard let url = Bundle.main.url(forResource: "oui", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return Table() }
        return Table.parse(text)
    }()

    /// Loads the registry off the main thread so the first list that shows
    /// a manufacturer does not wait for it.
    static func warmUp() {
        Task.detached(priority: .utility) { _ = table.count }
    }
}
