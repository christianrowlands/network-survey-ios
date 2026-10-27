import CoreLocation
import Foundation
import SurveyCore
import Towers

/// Something placed on the map that can be grouped with its neighbors.
nonisolated protocol Clusterable: Sendable, Equatable {
    var id: String { get }
    var latitude: Double { get }
    var longitude: Double { get }
}

nonisolated extension MapPoint: Clusterable {}

nonisolated extension Tower: Clusterable {
    var latitude: Double { lat }
    var longitude: Double { lon }
}

/// One marker on the map: a single item or a group of nearby items.
nonisolated struct MapCluster<Point: Clusterable>: Identifiable, Equatable {
    var id: String
    var coordinate: CLLocationCoordinate2D
    var points: [Point]

    var isSingle: Bool { points.count == 1 }

    static func == (lhs: MapCluster, rhs: MapCluster) -> Bool {
        lhs.id == rhs.id && lhs.points == rhs.points
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

extension MapCluster where Point == MapPoint {
    /// The strongest member, which a single marker shows.
    var strongest: MapPoint { points.max { $0.rssi < $1.rssi } ?? points[0] }
}

/// Groups markers on a grid of screen-sized cells, so markers never overlap:
/// a zoomed-out map shows a few counted clusters, a zoomed-in map every item.
nonisolated enum MapClusterer {
    /// Cells are `cellPoints` wide on a map of `size` points showing the
    /// given span; a marker is at most about 44 points across.
    static func clusters<Point: Clusterable>(
        _ points: [Point], latitudeDelta: Double, longitudeDelta: Double, size: CGSize, cellPoints: Double = 60
    ) -> [MapCluster<Point>] {
        let width = max(Double(size.width), 1), height = max(Double(size.height), 1)
        let cellLat = max(latitudeDelta * cellPoints / height, 1e-7)
        let cellLon = max(longitudeDelta * cellPoints / width, 1e-7)
        var cells: [Cell: [Point]] = [:]
        for point in points {
            let cell = Cell(x: Int((point.longitude / cellLon).rounded(.down)), y: Int((point.latitude / cellLat).rounded(.down)))
            cells[cell, default: []].append(point)
        }
        // Neighboring cells can put groups almost on top of each other, so
        // join groups less than a cell apart on screen, biggest first.
        let groups = cells
            .map { Group<Point>(key: $0.key, members: $0.value) }
            .sorted { ($0.members.count, $0.key.x, $0.key.y) > ($1.members.count, $1.key.x, $1.key.y) }
        var merged: [Group<Point>] = []
        for group in groups {
            if let index = merged.firstIndex(where: {
                let dx = ($0.lon - group.lon) / cellLon, dy = ($0.lat - group.lat) / cellLat
                return dx * dx + dy * dy < 1
            }) {
                merged[index].members += group.members
            } else {
                merged.append(group)
            }
        }
        return merged.map { group in
            let id = group.members.count == 1 ? group.members[0].id : "cell-\(group.key.x)-\(group.key.y)"
            return MapCluster(id: id, coordinate: CLLocationCoordinate2D(latitude: group.lat, longitude: group.lon),
                              points: group.members)
        }
        .sorted { $0.id < $1.id }
    }

    private struct Group<Point: Clusterable> {
        var key: Cell
        var members: [Point]
        var lat: Double { members.map(\.latitude).reduce(0, +) / Double(max(members.count, 1)) }
        var lon: Double { members.map(\.longitude).reduce(0, +) / Double(max(members.count, 1)) }
    }

    private struct Cell: Hashable {
        var x: Int
        var y: Int
    }
}

/// Fewer track points for drawing: at most `limit`, evenly spaced, always
/// keeping the first and last.
nonisolated enum TrackThinner {
    static func thin<T>(_ points: [T], limit: Int = 1500) -> [T] {
        guard points.count > limit, limit >= 2 else { return points }
        let step = Double(points.count - 1) / Double(limit - 1)
        return (0..<limit).map { points[Int((Double($0) * step).rounded())] }
    }
}
