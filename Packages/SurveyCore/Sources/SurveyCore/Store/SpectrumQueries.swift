import Foundation
import GRDB

extension StoreQueries {
    /// Access points heard within `window` seconds of the session's latest
    /// beacon, for the spectrum chart. Ending at the latest beacon rather
    /// than now keeps a finished survey's last minutes on screen.
    public static func recentAccessPoints(
        _ db: Database, sessionID: String, window: TimeInterval = WifiSpectrum.recentWindow
    ) throws -> [AccessPointRow] {
        guard let latest = try Date.fetchOne(
            db, sql: "SELECT max(lastSeen) FROM accessPoint WHERE sessionId = ?", arguments: [sessionID]
        ) else { return [] }
        return try AccessPointRow.fetchAll(db, sql: """
            SELECT * FROM accessPoint WHERE sessionId = ? AND lastSeen >= ? ORDER BY channel, bssid
            """, arguments: [sessionID, latest.addingTimeInterval(-window)])
    }
}
