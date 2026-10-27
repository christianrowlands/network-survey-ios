import Foundation

/// Turns the cache's gaps in the visible area into at most one request. Every
/// box it returns is made of whole tiles, so a complete response fills them and
/// the next look at the same area is free. A port of the Android app's
/// `TowerFetchPlanner`.
public enum TowerFetchPlanner {
    /// Gaps over this share of the view: request the whole view rather than a
    /// ragged union of nearly the same size.
    static let wholeViewFraction = 0.8
    /// Expired tiles still have towers to show, so refresh them only when they
    /// make up this share of the view.
    static let refreshExpiredFraction = 0.5

    /// No towers are requested for a view wider than this, as on Android
    /// (about 200 km by 200 km).
    public static let maxViewArea = 40_000.0 * 1_000_000

    /// The box to request, or nil when the cache can serve the view.
    public static func plan(visible: Set<TileKey>, gaps: [TileKey: TowerTileCache.Gap]) -> GeoBounds? {
        guard !gaps.isEmpty, let view = union(visible) else { return nil }
        let viewArea = view.approximateArea

        if gaps.values.allSatisfy({ $0 == .expired }) {
            let expiredArea = gaps.keys.reduce(0) { $0 + $1.bounds.approximateArea }
            if expiredArea < viewArea * refreshExpiredFraction { return nil }
        }

        guard let missing = union(gaps.keys) else { return nil }
        return missing.approximateArea > viewArea * wholeViewFraction ? view : missing
    }

    private static func union(_ tiles: some Collection<TileKey>) -> GeoBounds? {
        tiles.lazy.map(\.bounds).reduce(nil) { $0?.union($1) ?? $1 }
    }
}
