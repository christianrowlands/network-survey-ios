import Foundation
import GRDB

/// One network of an import, and whether it is already on the watchlist.
public struct WatchlistImportRow: Sendable, Equatable, Identifiable {
    public var id: Int
    public var label: String
    public var ssid: String?
    public var bssid: String?
    public var isDuplicate: Bool
}

/// What an import would do, for the confirmation prompt.
public struct WatchlistImportPlan: Sendable, Equatable {
    public var rows: [WatchlistImportRow]
    public var addedCount: Int { rows.count - duplicateCount }
    public var duplicateCount: Int { rows.filter(\.isDuplicate).count }
    /// The new networks, in the link's order.
    public var toAdd: [WatchlistImportRow] { rows.filter { !$0.isDuplicate } }
}

/// Plans an import the way the Network Survey Android app does: each network
/// is normalized like one added by hand and compared with the watchlist and
/// with the networks before it in the link (SSID ignoring case, and BSSID).
/// Imports only add; entries already saved are never changed.
public enum WatchlistImportPlanner {
    public static func plan(existing: [WatchlistEntry], set: WatchlistImportSet) -> WatchlistImportPlan {
        var seen = Set(existing.map { WatchlistMatcher.dedupKey(ssid: $0.ssid, bssid: $0.bssid) })
        let rows = set.entries.enumerated().map { index, entry in
            let ssid = WatchlistMatcher.normalizeSSID(entry.ssid), bssid = WatchlistMatcher.normalizeBSSID(entry.bssid)
            let isNew = seen.insert(WatchlistMatcher.dedupKey(ssid: ssid, bssid: bssid)).inserted
            return WatchlistImportRow(
                id: index, label: WatchlistMatcher.resolveLabel(entry.label, ssid: ssid, bssid: bssid), ssid: ssid,
                bssid: bssid, isDuplicate: !isNew
            )
        }
        return WatchlistImportPlan(rows: rows)
    }
}

extension SurveyStore {
    /// Adds the networks of a link that are not on the watchlist yet, in one
    /// transaction. Returns how many were added and how many were already saved.
    @discardableResult
    public func importWatchlist(_ set: WatchlistImportSet, now: Date = Date()) async throws -> (added: Int, skipped: Int) {
        try await writer.write { db in
            let plan = WatchlistImportPlanner.plan(existing: try WatchlistEntry.fetchAll(db), set: set)
            for row in plan.toAdd {
                var entry = WatchlistEntry(label: row.label, ssid: row.ssid, bssid: row.bssid, createdAt: now)
                try entry.insert(db)
            }
            return (plan.addedCount, plan.duplicateCount)
        }
    }
}
