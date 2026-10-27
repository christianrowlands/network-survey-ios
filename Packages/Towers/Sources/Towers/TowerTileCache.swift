import Foundation

/// Towers fetched this session, grouped by `TileKey`, so repeat visits to an
/// area cost no requests. Each tower is in exactly one tile, so merging fetches
/// is a dictionary write and eviction drops whole tiles. A port of the Android
/// app's `TowerTileCache`. Not thread safe: use it from one actor.
public final class TowerTileCache {
    /// Why a visible tile needs a fetch.
    public enum Gap: Sendable, Equatable {
        /// Never fetched, or evicted.
        case absent
        /// Fetched, but older than the time to live. Its towers still show.
        case expired
        /// The response was cut off at the server's cap, and a smaller request
        /// could get the rest.
        case incomplete
    }

    private struct Entry {
        var towers: [String: Tower] = [:]
        var fetchedAt: Date?
        var complete = false
        var truncatedArea: Double?
        var lastUsed = Date.distantPast
    }

    /// Most towers kept before the least recently used tiles are dropped.
    public static let defaultBudget = 20_000
    /// How long a fetched tile is trusted.
    public static let defaultTimeToLive: TimeInterval = 45 * 60
    /// A cut-off tile is only asked for again with a request under this share
    /// of the cut-off one's area; a same size request returns the same rows.
    static let retryTruncatedFraction = 0.5

    private let budget: Int
    private let timeToLive: TimeInterval
    private var tiles: [TileKey: Entry] = [:]
    private var count = 0
    private var snapshotVersion = -1
    private var snapshot: [Tower] = []

    /// Changes whenever the cached towers change.
    public private(set) var version = 0

    public init(budget: Int = TowerTileCache.defaultBudget, timeToLive: TimeInterval = TowerTileCache.defaultTimeToLive) {
        self.budget = budget
        self.timeToLive = timeToLive
    }

    /// Records one area response. Tiles wholly inside `request` become complete,
    /// unless the response was truncated: then they remember the request's area
    /// so the same request is not repeated.
    public func ingest(_ request: GeoBounds, towers: [Tower], truncated: Bool, now: Date) {
        var changed = false
        for tower in towers {
            let key = TileKey(latitude: tower.lat, longitude: tower.lon)
            var entry = tiles[key] ?? Entry()
            if let existing = entry.towers[tower.id] {
                if tower.updatedAt >= existing.updatedAt && tower != existing {
                    entry.towers[tower.id] = tower
                    changed = true
                }
            } else {
                entry.towers[tower.id] = tower
                count += 1
                changed = true
            }
            entry.lastUsed = now
            tiles[key] = entry
        }

        let area = request.approximateArea
        for key in TileKey.covering(request) where request.contains(key.bounds) {
            var entry = tiles[key] ?? Entry()
            entry.fetchedAt = now
            entry.lastUsed = now
            entry.complete = !truncated
            entry.truncatedArea = truncated ? area : nil
            tiles[key] = entry
        }

        if evictToBudget() { changed = true }
        if changed { version += 1 }
    }

    /// The visible tiles the cache cannot serve as is, and why. Also marks every
    /// visible tile as recently used, so it outlives the ones off screen.
    /// `requestArea` is the area of the request the caller would make.
    public func gaps(in visible: Set<TileKey>, requestArea: Double, now: Date) -> [TileKey: Gap] {
        var result: [TileKey: Gap] = [:]
        for key in visible {
            guard var entry = tiles[key] else {
                result[key] = .absent
                continue
            }
            entry.lastUsed = now
            tiles[key] = entry
            guard let fetchedAt = entry.fetchedAt else {
                result[key] = .absent
                continue
            }
            if now.timeIntervalSince(fetchedAt) > timeToLive {
                result[key] = .expired
            } else if !entry.complete {
                if let truncatedArea = entry.truncatedArea, requestArea >= truncatedArea * Self.retryTruncatedFraction {
                    continue
                }
                result[key] = .incomplete
            }
        }
        return result
    }

    /// Towers held in the given tiles.
    public func towerCount(in visible: Set<TileKey>) -> Int {
        visible.reduce(0) { $0 + (tiles[$1]?.towers.count ?? 0) }
    }

    /// True when any of the given tiles came back cut off.
    public func hasIncomplete(in visible: Set<TileKey>) -> Bool {
        visible.contains { tiles[$0].map { $0.fetchedAt != nil && !$0.complete } ?? false }
    }

    /// Drops everything, for a filter change.
    public func removeAll() {
        guard !tiles.isEmpty else { return }
        tiles.removeAll()
        count = 0
        version += 1
    }

    /// Every cached tower, rebuilt only after a change.
    public var towers: [Tower] {
        if snapshotVersion != version {
            snapshot = tiles.values.flatMap { $0.towers.values }
            snapshotVersion = version
        }
        return snapshot
    }

    /// Drops the least recently used tiles until the budget fits.
    private func evictToBudget() -> Bool {
        guard count > budget else { return false }
        for (key, entry) in tiles.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }) {
            guard count > budget else { break }
            count -= entry.towers.count
            tiles[key] = nil
        }
        return true
    }
}
