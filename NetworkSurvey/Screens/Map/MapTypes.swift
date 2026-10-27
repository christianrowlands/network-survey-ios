import MapKit
import SurveyCore
import SwiftUI

/// Requests from other screens to the Map.
@Observable
final class MapCommands {
    /// Open the Map in privacy zone editing.
    var editZones = false
}

/// The visible region and the map's size, for clustering.
nonisolated struct Viewport: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var latitudeDelta: Double
    var longitudeDelta: Double
    var size: CGSize

    init(_ region: MKCoordinateRegion, size: CGSize) {
        latitude = region.center.latitude
        longitude = region.center.longitude
        latitudeDelta = region.span.latitudeDelta
        longitudeDelta = region.span.longitudeDelta
        self.size = size
    }
}

extension GeoPoint {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
