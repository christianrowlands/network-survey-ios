import Foundation

/// A cell technology, as the NS Tower Service names it.
public enum TowerRadio: String, CaseIterable, Codable, Sendable, Comparable {
    case gsm = "GSM"
    case cdma = "CDMA"
    case umts = "UMTS"
    case lte = "LTE"
    case nr = "NR"

    /// The generation shown on a marker.
    public var generation: String {
        switch self {
        case .gsm, .cdma: "2G"
        case .umts: "3G"
        case .lte: "4G"
        case .nr: "5G"
        }
    }

    /// The name of the area code for this technology (LAC for 2G and 3G, TAC after).
    public var areaName: String {
        switch self {
        case .gsm, .cdma, .umts: "LAC"
        case .lte, .nr: "TAC"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// Where a tower record comes from.
public enum TowerSource: String, CaseIterable, Codable, Sendable {
    case openCelliD = "OpenCelliD"
    /// Poland only.
    case btSearch = "BTSearch"
}

/// A tower from the NS Tower Service (`/v2/cells/*`). MCC and MNC are strings so
/// leading zeros survive.
public struct Tower: Codable, Sendable, Hashable, Identifiable {
    public var lat: Double
    public var lon: Double
    public var mcc: String
    public var mnc: String
    public var area: Int
    public var cid: Int64
    /// The PCI for LTE and NR, the PSC for UMTS.
    public var unit: Int
    public var averageSignal: Int
    /// Estimated coverage radius in meters, 0 when unknown.
    public var range: Int
    public var samples: Int
    public var changeable: Int
    /// Unix seconds.
    public var createdAt: Int64
    /// Unix seconds.
    public var updatedAt: Int64
    /// The raw radio name; see `technology`.
    public var radio: String
    public var source: String
    public var comments: String?

    public init(
        lat: Double, lon: Double, mcc: String, mnc: String, area: Int, cid: Int64,
        unit: Int = 0, averageSignal: Int = 0, range: Int = 0, samples: Int = 0, changeable: Int = 0,
        createdAt: Int64 = 0, updatedAt: Int64 = 0, radio: String, source: String = TowerSource.openCelliD.rawValue,
        comments: String? = nil
    ) {
        self.lat = lat
        self.lon = lon
        self.mcc = mcc
        self.mnc = mnc
        self.area = area
        self.cid = cid
        self.unit = unit
        self.averageSignal = averageSignal
        self.range = range
        self.samples = samples
        self.changeable = changeable
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.radio = radio
        self.source = source
        self.comments = comments
    }

    enum CodingKeys: String, CodingKey {
        case lat, lon, mcc, mnc, area, cid, unit, range, samples, changeable, radio, source, comments
        case averageSignal = "average_signal"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lat = try c.decode(Double.self, forKey: .lat)
        lon = try c.decode(Double.self, forKey: .lon)
        mcc = try c.decode(String.self, forKey: .mcc)
        mnc = try c.decode(String.self, forKey: .mnc)
        area = try c.decode(Int.self, forKey: .area)
        cid = try c.decode(Int64.self, forKey: .cid)
        unit = try c.decodeIfPresent(Int.self, forKey: .unit) ?? 0
        averageSignal = try c.decodeIfPresent(Int.self, forKey: .averageSignal) ?? 0
        range = try c.decodeIfPresent(Int.self, forKey: .range) ?? 0
        samples = try c.decodeIfPresent(Int.self, forKey: .samples) ?? 0
        changeable = try c.decodeIfPresent(Int.self, forKey: .changeable) ?? 0
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
        radio = try c.decode(String.self, forKey: .radio)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        comments = try c.decodeIfPresent(String.self, forKey: .comments)
    }

    /// The same cell from the same source has the same ID, whatever its statistics.
    public var id: String { "\(towerID)-\(source)" }

    /// The cell's identity, matching the Android app's tower ID (`mcc-mnc-area-cid`).
    public var towerID: String { "\(mcc)-\(mnc)-\(area)-\(cid)" }

    /// The operator, as `mcc-mnc`.
    public var plmn: Plmn { Plmn(mcc: mcc, mnc: mnc) }

    public var technology: TowerRadio? { TowerRadio(rawValue: radio.uppercased()) }

    public var towerSource: TowerSource? { TowerSource(rawValue: source) }

    /// LTE only: the eNodeB ID and sector, taken from the 28-bit ECI.
    public var eNodeB: (id: Int64, sector: Int64)? {
        guard technology == .lte, cid > 255 else { return nil }
        return (cid >> 8, cid & 0xFF)
    }

    public var createdDate: Date? { createdAt > 0 ? Date(timeIntervalSince1970: TimeInterval(createdAt)) : nil }
    public var updatedDate: Date? { updatedAt > 0 ? Date(timeIntervalSince1970: TimeInterval(updatedAt)) : nil }
}

/// A mobile network operator code.
public struct Plmn: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public var mcc: String
    public var mnc: String

    public init(mcc: String, mnc: String) {
        self.mcc = mcc
        self.mnc = mnc
    }

    /// Parses "mcc-mnc" (3 digits, then 2 or 3), as `description` writes it.
    public init?(string: String) {
        let parts = string.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 3, (2...3).contains(parts[1].count),
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        self.init(mcc: String(parts[0]), mnc: String(parts[1]))
    }

    public var description: String { "\(mcc)-\(mnc)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.mcc, lhs.mnc) < (rhs.mcc, rhs.mnc)
    }
}

/// One `/v2/cells/area` or `/v2/cells/search` response.
public struct TowerBatch: Sendable, Equatable {
    public var towers: [Tower]
    /// True when the server hit its row cap and more towers match.
    public var truncated: Bool

    public init(towers: [Tower], truncated: Bool) {
        self.towers = towers
        self.truncated = truncated
    }

    public static let empty = TowerBatch(towers: [], truncated: false)
}

extension TowerBatch: Decodable {
    enum CodingKeys: String, CodingKey { case cells, truncated }

    public init(from decoder: any Decoder) throws {
        // The server omits empty fields.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        towers = try c.decodeIfPresent([Tower].self, forKey: .cells) ?? []
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}
