import Foundation

/// One position from the phone or a board GPS.
public struct LocationSample: Sendable, Equatable, Codable {
    public enum Source: String, Sendable, Codable {
        case phone
        case boardGPS
    }

    public var latitude: Double
    public var longitude: Double
    /// Meters above mean sea level.
    public var altitude: Double?
    /// Meters (68% confidence). For board fixes, estimated from HDOP.
    public var horizontalAccuracy: Double?
    /// Meters per second.
    public var speed: Double?
    /// Degrees from true north.
    public var course: Double?
    public var timestamp: Date
    public var source: Source

    public init(
        latitude: Double, longitude: Double, altitude: Double? = nil, horizontalAccuracy: Double? = nil,
        speed: Double? = nil, course: Double? = nil, timestamp: Date, source: Source = .phone
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.course = course
        self.timestamp = timestamp
        self.source = source
    }

    public var point: GeoPoint { GeoPoint(latitude: latitude, longitude: longitude) }
}
