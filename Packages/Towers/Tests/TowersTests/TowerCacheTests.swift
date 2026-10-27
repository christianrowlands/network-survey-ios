import Foundation
import Testing
@testable import Towers

/// Tiles near Denver: a 3 by 3 block plus the box covering it exactly.
private enum Grid {
    static let origin = TileKey(latitude: 39.74, longitude: -104.99)

    static func tile(_ dx: Int, _ dy: Int) -> TileKey { TileKey(x: origin.x + dx, y: origin.y + dy) }

    static func box(_ tiles: [TileKey]) -> GeoBounds {
        tiles.dropFirst().reduce(tiles[0].bounds) { $0.union($1.bounds) }
    }

    static let all = (0..<3).flatMap { dx in (0..<3).map { dy in tile(dx, dy) } }

    static func tower(in tile: TileKey, cid: Int64, updatedAt: Int64 = 100, range: Int = 500) -> Tower {
        let b = tile.bounds
        return Tower(lat: (b.south + b.north) / 2, lon: (b.west + b.east) / 2, mcc: "310", mnc: "410",
                     area: 1, cid: cid, range: range, updatedAt: updatedAt, radio: "LTE")
    }
}

@Suite struct TowerTileCacheTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func aTowerIsKeptInTheTileItSitsIn() {
        let cache = TowerTileCache()
        let tile = Grid.tile(1, 1)
        cache.ingest(Grid.box(Grid.all), towers: [Grid.tower(in: tile, cid: 1)], truncated: false, now: t0)
        #expect(cache.towers.count == 1)
        #expect(cache.towerCount(in: [tile]) == 1)
        #expect(cache.towerCount(in: [Grid.tile(0, 0)]) == 0)
    }

    @Test func tilesInsideACompleteRequestHaveNoGaps() {
        let cache = TowerTileCache()
        let box = Grid.box(Grid.all)
        cache.ingest(box, towers: [], truncated: false, now: t0)
        #expect(cache.gaps(in: Set(Grid.all), requestArea: box.approximateArea, now: t0).isEmpty)
        #expect(cache.gaps(in: [Grid.tile(5, 5)], requestArea: 1, now: t0) == [Grid.tile(5, 5): .absent])
    }

    @Test func expiredTilesAreReportedButKeepTheirTowers() {
        let cache = TowerTileCache(timeToLive: 60)
        let tile = Grid.tile(0, 0)
        cache.ingest(Grid.box([tile]), towers: [Grid.tower(in: tile, cid: 1)], truncated: false, now: t0)
        let later = t0.addingTimeInterval(61)
        #expect(cache.gaps(in: [tile], requestArea: 1, now: later) == [tile: .expired])
        #expect(cache.towers.count == 1)
    }

    @Test func aTruncatedTileIsRetriedOnlyWithASmallerRequest() {
        let cache = TowerTileCache()
        let box = Grid.box(Grid.all)
        let area = box.approximateArea
        cache.ingest(box, towers: [], truncated: true, now: t0)
        #expect(cache.hasIncomplete(in: Set(Grid.all)))
        #expect(cache.gaps(in: Set(Grid.all), requestArea: area, now: t0).isEmpty)
        #expect(cache.gaps(in: [Grid.tile(0, 0)], requestArea: area * 0.4, now: t0) == [Grid.tile(0, 0): .incomplete])
    }

    @Test func aNewerCopyReplacesAnOlderOneButNotTheReverse() {
        let cache = TowerTileCache()
        let tile = Grid.tile(0, 0)
        cache.ingest(Grid.box([tile]), towers: [Grid.tower(in: tile, cid: 1, updatedAt: 100, range: 500)], truncated: false, now: t0)
        cache.ingest(Grid.box([tile]), towers: [Grid.tower(in: tile, cid: 1, updatedAt: 200, range: 900)], truncated: false, now: t0)
        cache.ingest(Grid.box([tile]), towers: [Grid.tower(in: tile, cid: 1, updatedAt: 50, range: 100)], truncated: false, now: t0)
        #expect(cache.towers.map(\.range) == [900])
    }

    @Test func leastRecentlyUsedTilesAreEvictedWhole() {
        let cache = TowerTileCache(budget: 3)
        let old = Grid.tile(0, 0), seen = Grid.tile(1, 0), new = Grid.tile(2, 0)
        cache.ingest(Grid.box([old]), towers: [Grid.tower(in: old, cid: 1), Grid.tower(in: old, cid: 2)], truncated: false, now: t0)
        cache.ingest(Grid.box([seen]), towers: [Grid.tower(in: seen, cid: 3)], truncated: false, now: t0.addingTimeInterval(1))
        // Looking at the old tile again keeps it; the unseen one goes instead.
        _ = cache.gaps(in: [old], requestArea: 1, now: t0.addingTimeInterval(2))
        cache.ingest(Grid.box([new]), towers: [Grid.tower(in: new, cid: 4)], truncated: false, now: t0.addingTimeInterval(3))
        #expect(Set(cache.towers.map(\.cid)) == [1, 2, 4])
    }

    @Test func versionChangesOnlyWithContent() {
        let cache = TowerTileCache()
        let tile = Grid.tile(0, 0)
        cache.ingest(Grid.box([tile]), towers: [Grid.tower(in: tile, cid: 1)], truncated: false, now: t0)
        let version = cache.version
        cache.ingest(Grid.box([tile]), towers: [Grid.tower(in: tile, cid: 1)], truncated: false, now: t0)
        #expect(cache.version == version)
        cache.removeAll()
        #expect(cache.version == version + 1)
        #expect(cache.towers.isEmpty)
    }
}

@Suite struct TowerFetchPlannerTests {
    let visible = Set(Grid.all)

    @Test func aCoveredViewNeedsNoRequest() {
        #expect(TowerFetchPlanner.plan(visible: visible, gaps: [:]) == nil)
    }

    @Test func aColumnUncoveredByAPanIsRequestedAsAStrip() {
        let column = [Grid.tile(2, 0), Grid.tile(2, 1), Grid.tile(2, 2)]
        let plan = TowerFetchPlanner.plan(visible: visible, gaps: Dictionary(uniqueKeysWithValues: column.map { ($0, .absent) }))
        #expect(plan == Grid.box(column))
    }

    @Test func aMostlyUncoveredViewIsRequestedWhole() {
        let gaps = Dictionary(uniqueKeysWithValues: Grid.all.dropLast().map { ($0, TowerTileCache.Gap.absent) })
        #expect(TowerFetchPlanner.plan(visible: visible, gaps: gaps) == Grid.box(Grid.all))
    }

    @Test func aFewExpiredTilesWaitAndManyAreRefreshed() {
        #expect(TowerFetchPlanner.plan(visible: visible, gaps: [Grid.tile(0, 0): .expired]) == nil)
        let many = Dictionary(uniqueKeysWithValues: Grid.all.prefix(6).map { ($0, TowerTileCache.Gap.expired) })
        #expect(TowerFetchPlanner.plan(visible: visible, gaps: many) != nil)
    }

    @Test func expiredTilesRideAlongWithAnAbsentOne() {
        let gaps: [TileKey: TowerTileCache.Gap] = [Grid.tile(0, 0): .expired, Grid.tile(1, 0): .absent]
        #expect(TowerFetchPlanner.plan(visible: visible, gaps: gaps) == Grid.box([Grid.tile(0, 0), Grid.tile(1, 0)]))
    }
}
