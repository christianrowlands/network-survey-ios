import Foundation

/// How recently a tower must have been seen to show.
public enum TowerAge: String, CaseIterable, Codable, Sendable {
    case any, sixMonths, oneYear, twoYears, fiveYears

    /// The age for a stored month count; values not offered read as any.
    public init(months: Int) {
        self = Self.allCases.first { $0.months == months } ?? .any
    }

    public var months: Int? {
        switch self {
        case .any: nil
        case .sixMonths: 6
        case .oneYear: 12
        case .twoYears: 24
        case .fiveYears: 60
        }
    }

    /// The `updated_after` cutoff in Unix seconds. Months are 30 days, as on
    /// Android, so both apps ask for the same towers.
    public func cutoff(from now: Date) -> Int64? {
        months.map { Int64(now.timeIntervalSince1970) - Int64($0) * 30 * 86_400 }
    }
}

/// What the tower layer asks the server for. Any change invalidates the cache.
public struct TowerFilters: Codable, Sendable, Hashable {
    public var technologies: Set<TowerRadio>
    /// One operator, or nil for all.
    public var plmn: Plmn?
    public var source: TowerSource
    /// Ignored by the server for BTSearch.
    public var maxAge: TowerAge

    public init(
        technologies: Set<TowerRadio> = [.lte, .nr], plmn: Plmn? = nil,
        source: TowerSource = .openCelliD, maxAge: TowerAge = .any
    ) {
        self.technologies = technologies
        self.plmn = plmn
        self.source = source
        self.maxAge = maxAge
    }

    /// True when the server applies the age filter to the chosen source.
    public var ageApplies: Bool { source == .openCelliD }

    func queryItems(bbox: String, now: Date) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "bbox", value: bbox),
            URLQueryItem(name: "radio", value: technologies.sorted().map(\.rawValue).joined(separator: ",")),
            URLQueryItem(name: "source", value: source.rawValue),
        ]
        if let plmn {
            items.append(URLQueryItem(name: "mcc", value: plmn.mcc))
            items.append(URLQueryItem(name: "mnc", value: plmn.mnc))
        }
        if let cutoff = maxAge.cutoff(from: now) {
            items.append(URLQueryItem(name: "updated_after", value: String(cutoff)))
        }
        return items
    }
}
