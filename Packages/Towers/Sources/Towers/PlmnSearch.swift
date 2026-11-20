import Foundation

/// What a PLMN search looks for: an MCC or MCC-MNC, or a name.
public enum PlmnSearchQuery: Sendable, Equatable {
    /// MCC digits (a prefix when shorter than 3), and the start of an MNC as
    /// typed ("1" finds 100 to 199, "01" finds 01 and 010 to 019).
    case code(mcc: String, mnc: String?)
    /// Matched anywhere in the country, ISO code, operator, brand, region,
    /// TADIG or codes, ignoring case.
    case text(String)

    public static let minimumLength = 2
    public static let maximumLength = 64

    /// Reads what was typed: "310", "310-260", "310260" or "310 26" as codes,
    /// anything else as text. Nil when it is too short to search.
    public init?(_ input: String) {
        let trimmed = String(input.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumLength))
        guard trimmed.count >= Self.minimumLength else { return nil }
        if let match = trimmed.wholeMatch(of: /([0-9]{3})[\-\s]?([0-9]{0,3})/) {
            let mnc = String(match.2)
            self = .code(mcc: String(match.1), mnc: mnc.isEmpty ? nil : mnc)
        } else if trimmed.wholeMatch(of: /[0-9]{2}/) != nil {
            self = .code(mcc: trimmed, mnc: nil)
        } else {
            self = .text(trimmed)
        }
    }

    var queryItems: [URLQueryItem] {
        switch self {
        case .code(let mcc, let mnc):
            [URLQueryItem(name: "mcc", value: mcc)] + (mnc.map { [URLQueryItem(name: "mnc", value: $0)] } ?? [])
        case .text(let text):
            [URLQueryItem(name: "q", value: text)]
        }
    }
}

/// One operator entry in the service's MCC-MNC list. A shared network has
/// one entry per operator or territory.
public struct PlmnRecord: Sendable, Hashable, Decodable, Identifiable {
    public var mcc: String
    /// As the registry writes it, 2 or 3 digits.
    public var mnc: String
    public var region: String?
    public var country: String?
    /// ISO 3166 code, or several joined with "/" for a record that covers
    /// several territories.
    public var iso: String?
    public var `operator`: String?
    public var brand: String?
    /// The GSMA roaming identifier.
    public var tadig: String?
    /// Frequency bands, as "GSM 900 / LTE 1800".
    public var bands: String?
    /// The source's word: "Operational", "Not operational", "Unknown", "Reserved" and a few more.
    public var status: String?

    public init(
        mcc: String, mnc: String, region: String? = nil, country: String? = nil, iso: String? = nil,
        operator: String? = nil, brand: String? = nil, tadig: String? = nil, bands: String? = nil, status: String? = nil
    ) {
        self.mcc = mcc
        self.mnc = mnc
        self.region = region
        self.country = country
        self.iso = iso
        self.operator = `operator`
        self.brand = brand
        self.tadig = tadig
        self.bands = bands
        self.status = status
    }

    public var plmn: Plmn { Plmn(mcc: mcc, mnc: mnc) }

    public var id: String {
        [mcc, mnc, iso, `operator`, brand, region, tadig, status].map { $0 ?? "" }.joined(separator: "|")
    }

    /// The brand, else the operator.
    public var name: String? {
        Self.nonBlank(brand) ?? Self.nonBlank(`operator`)
    }

    /// The operator, when there is a brand with another name.
    public var operatorName: String? {
        guard let brand = Self.nonBlank(brand), let name = Self.nonBlank(`operator`),
              brand.caseInsensitiveCompare(name) != .orderedSame else { return nil }
        return name
    }

    public var isOperational: Bool {
        status?.caseInsensitiveCompare("Operational") == .orderedSame
    }

    /// The flag for a single 2-letter ISO code; nil for several or none.
    public var flag: String? {
        guard let code = iso?.trimmingCharacters(in: .whitespaces).uppercased(), code.count == 2, code != "XX",
              code.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }) else { return nil }
        let scalars = code.unicodeScalars.compactMap { UnicodeScalar(0x1F1E6 + $0.value - 0x41) }
        return String(String.UnicodeScalarView(scalars))
    }

    /// By MCC and MNC as numbers, then country and name.
    public static func codeOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        let left = (Int(lhs.mcc) ?? .max, Int(lhs.mnc) ?? .max, lhs.mnc.count)
        let right = (Int(rhs.mcc) ?? .max, Int(rhs.mnc) ?? .max, rhs.mnc.count)
        if left != right { return left < right }
        return ((lhs.country ?? ""), (lhs.name ?? "")) < ((rhs.country ?? ""), (rhs.name ?? ""))
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text
    }
}

/// The operators a search found.
public struct PlmnSearchResult: Sendable, Equatable {
    public var records: [PlmnRecord]
    /// More matched than the service returns (`TowerClient.plmnSearchLimit`).
    public var truncated: Bool

    public init(records: [PlmnRecord], truncated: Bool) {
        self.records = records
        self.truncated = truncated
    }
}

extension TowerClient {
    /// The most results the service returns for one search.
    public static let plmnSearchLimit = 50

    /// Operators matching `query` (`/v2/plmn/search`), by MCC-MNC.
    public func searchOperators(_ query: PlmnSearchQuery) async throws(TowerServiceError) -> PlmnSearchResult {
        let limit = URLQueryItem(name: "limit", value: String(Self.plmnSearchLimit))
        let data = try await get("v2/plmn/search", query.queryItems + [limit])
        guard let response = try decode(PlmnSearchResponse.self, data) else {
            return PlmnSearchResult(records: [], truncated: false)
        }
        var seen: Set<PlmnRecord> = []
        let records = (response.results ?? []).filter { seen.insert($0).inserted }
        return PlmnSearchResult(records: records.sorted(by: PlmnRecord.codeOrder), truncated: response.truncated ?? false)
    }
}

private struct PlmnSearchResponse: Decodable {
    var results: [PlmnRecord]?
    var truncated: Bool?
}
