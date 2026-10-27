import Foundation

/// A latitude and longitude box. Tile membership treats the south and west
/// edges as inclusive and the north and east edges as exclusive.
public struct GeoBounds: Hashable, Sendable {
    public var south: Double
    public var west: Double
    public var north: Double
    public var east: Double

    public init(south: Double, west: Double, north: Double, east: Double) {
        self.south = south
        self.west = west
        self.north = north
        self.east = east
    }

    /// A box around a center point, as a map reports its visible region.
    public init(latitude: Double, longitude: Double, latitudeDelta: Double, longitudeDelta: Double) {
        self.init(
            south: latitude - latitudeDelta / 2, west: longitude - longitudeDelta / 2,
            north: latitude + latitudeDelta / 2, east: longitude + longitudeDelta / 2
        )
    }

    /// True when the box has an area and does not cross the antimeridian.
    public var isQueryable: Bool { south < north && west < east }

    public func union(_ other: GeoBounds) -> GeoBounds {
        GeoBounds(
            south: min(south, other.south), west: min(west, other.west),
            north: max(north, other.north), east: max(east, other.east)
        )
    }

    /// True when `other` is entirely inside this box.
    public func contains(_ other: GeoBounds) -> Bool {
        other.south >= south && other.west >= west && other.north <= north && other.east <= east
    }

    public func contains(latitude: Double, longitude: Double) -> Bool {
        latitude >= south && latitude <= north && longitude >= west && longitude <= east
    }

    /// Width times height on an equirectangular projection. Good enough to
    /// compare request sizes, which is all it is used for.
    public var approximateArea: Double {
        let midLatitude = (south + north) / 2 * .pi / 180
        let height = (north - south) * Self.metersPerDegree
        let width = (east - west) * Self.metersPerDegree * cos(midLatitude)
        return max(height * width, 0)
    }

    /// The `bbox` query parameter (`swLat,swLon,neLat,neLon`), or nil when the
    /// server would reject the box: not finite, out of range, empty, inverted or
    /// across the antimeridian. Mirrors `ValidateBBox` in the tower service, so
    /// a skipped query replaces a sure 400. Out-of-range boxes are not clamped,
    /// since a clamped world view would show an arbitrary slice as if complete.
    public var bboxParameter: String? {
        let values = [south, west, north, east]
        guard values.allSatisfy(\.isFinite),
              (-90...90).contains(south), (-90...90).contains(north),
              (-180...180).contains(west), (-180...180).contains(east),
              isQueryable else { return nil }
        return values.map { String($0) }.joined(separator: ",")
    }

    static let metersPerDegree = 111_320.0
}

/// One slippy map tile at `TileKey.zoom`. A tower belongs to the tile that
/// holds its own position, so each tower is in exactly one tile.
public struct TileKey: Hashable, Sendable {
    public var x: Int
    public var y: Int

    /// About 3 to 5 km across at mid latitudes: a street view needs a few
    /// tiles and the widest allowed view is around a thousand.
    public static let zoom = 13

    /// Web Mercator stops here.
    static let maxLatitude = 85.05112878

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    public init(latitude: Double, longitude: Double) {
        let n = 1 << Self.zoom
        let latitude = min(max(latitude, -Self.maxLatitude), Self.maxLatitude) * .pi / 180
        let x = Int(floor((longitude + 180) / 360 * Double(n)))
        let y = Int(floor((1 - log(tan(latitude) + 1 / cos(latitude)) / .pi) / 2 * Double(n)))
        self.init(x: min(max(x, 0), n - 1), y: min(max(y, 0), n - 1))
    }

    public var bounds: GeoBounds {
        let n = Double(1 << Self.zoom)
        return GeoBounds(
            south: Self.latitude(ofRow: y + 1, n: n), west: Double(x) / n * 360 - 180,
            north: Self.latitude(ofRow: y, n: n), east: Double(x + 1) / n * 360 - 180
        )
    }

    /// Every tile touching `bounds`; none for a box that is not queryable.
    public static func covering(_ bounds: GeoBounds) -> Set<TileKey> {
        guard bounds.isQueryable else { return [] }
        let southWest = TileKey(latitude: bounds.south, longitude: bounds.west)
        let northEast = TileKey(latitude: bounds.north, longitude: bounds.east)
        var tiles = Set<TileKey>()
        for x in southWest.x...northEast.x {
            for y in northEast.y...southWest.y {
                tiles.insert(TileKey(x: x, y: y))
            }
        }
        return tiles
    }

    private static func latitude(ofRow y: Int, n: Double) -> Double {
        atan(sinh(.pi * (1 - 2 * Double(y) / n))) * 180 / .pi
    }
}
