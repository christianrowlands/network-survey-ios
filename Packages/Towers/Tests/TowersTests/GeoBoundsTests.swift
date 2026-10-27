import Testing
@testable import Towers

@Suite struct BBoxParameterTests {
    @Test func aNormalBoxIsFormattedSouthWestFirst() {
        #expect(GeoBounds(south: 40.0, west: -105.5, north: 40.5, east: -105.0).bboxParameter == "40.0,-105.5,40.5,-105.0")
    }

    @Test func emptyAndInvertedBoxesAreRejected() {
        #expect(GeoBounds(south: 0, west: 0, north: 0, east: 0).bboxParameter == nil)
        #expect(GeoBounds(south: 40, west: -105, north: 40, east: -104).bboxParameter == nil)
        #expect(GeoBounds(south: 40, west: -105, north: 41, east: -105).bboxParameter == nil)
        #expect(GeoBounds(south: 41, west: -104, north: 40, east: -105).bboxParameter == nil)
    }

    @Test func outOfRangeValuesAreRejectedNotClamped() {
        #expect(GeoBounds(south: -91, west: 0, north: 10, east: 10).bboxParameter == nil)
        #expect(GeoBounds(south: 0, west: 0, north: 91, east: 10).bboxParameter == nil)
        #expect(GeoBounds(south: 0, west: -181, north: 10, east: 10).bboxParameter == nil)
        #expect(GeoBounds(south: 0, west: 0, north: 10, east: 181).bboxParameter == nil)
        #expect(GeoBounds(south: .nan, west: 0, north: 10, east: 10).bboxParameter == nil)
        #expect(GeoBounds(south: 0, west: 0, north: .infinity, east: 10).bboxParameter == nil)
    }

    @Test func aViewAcrossTheAntimeridianIsRejected() {
        // A map centered on the antimeridian reports a west edge past 180.
        #expect(GeoBounds(latitude: -17, longitude: 179.9, latitudeDelta: 0.1, longitudeDelta: 0.4).bboxParameter == nil)
        #expect(GeoBounds(south: -17, west: 179.8, north: -16.9, east: -179.8).bboxParameter == nil)
    }

    @Test func theWidestValidBoxIsAccepted() {
        #expect(GeoBounds(south: -90, west: -180, north: 90, east: 180).bboxParameter == "-90.0,-180.0,90.0,180.0")
    }
}

@Suite struct TileKeyTests {
    @Test func aPointIsInsideItsOwnTile() {
        let key = TileKey(latitude: 52.2297, longitude: 21.0122)
        #expect(key.bounds.contains(latitude: 52.2297, longitude: 21.0122))
    }

    @Test func polesAndEdgesClampToTheGrid() {
        let n = 1 << TileKey.zoom
        #expect(TileKey(latitude: 89.9, longitude: 180).y == 0)
        #expect(TileKey(latitude: 89.9, longitude: 180).x == n - 1)
        #expect(TileKey(latitude: -89.9, longitude: -180) == TileKey(x: 0, y: n - 1))
    }

    @Test func coveringReturnsEveryTouchedTile() {
        let a = TileKey(x: 4000, y: 3000), b = TileKey(x: 4002, y: 3001)
        let box = GeoBounds(south: b.bounds.south + 0.001, west: a.bounds.west + 0.001,
                            north: a.bounds.north - 0.001, east: b.bounds.east - 0.001)
        #expect(TileKey.covering(box).count == 6)
        #expect(TileKey.covering(GeoBounds(south: 1, west: 1, north: 1, east: 2)).isEmpty)
    }
}
