import Foundation

/// A WGS84 position.
public struct GeoPoint: Sendable, Hashable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Great-circle distance in meters (haversine, mean Earth radius).
    public func distance(to other: GeoPoint) -> Double {
        let earthRadius = 6_371_008.8
        let lat1 = latitude * .pi / 180, lat2 = other.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(a)))
    }
}

/// A circle on the map. Records and track points inside it are never stored.
public struct PrivacyZone: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var center: GeoPoint
    public var radiusMeters: Double

    public init(id: UUID = UUID(), name: String = "", center: GeoPoint, radiusMeters: Double) {
        self.id = id
        self.name = name
        self.center = center
        self.radiusMeters = radiusMeters
    }

    /// True when the point, widened by `accuracy` meters, may be inside: the
    /// check fails closed on a coarse fix.
    public func contains(_ point: GeoPoint, accuracy: Double = 0) -> Bool {
        center.distance(to: point) - max(accuracy, 0) <= radiusMeters
    }
}

/// One ignore list entry.
public struct IgnoreEntry: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        /// Exact, case-sensitive network name.
        case ssid
        /// An access point address; matches AP BSSIDs and the BSSID a client is associated with.
        case bssid
        /// Any address: AP, client or BLE device.
        case mac
        /// The start of any address, for example an OUI ("02:00:5E").
        case macPrefix
    }

    public var id: UUID
    public var kind: Kind
    public var value: String
    public var note: String

    public init(id: UUID = UUID(), kind: Kind, value: String, note: String = "") {
        self.id = id
        self.kind = kind
        self.value = value
        self.note = note
    }
}

public enum MACAddress {
    /// "AA:BB:CC:DD:EE:FF" from raw bytes.
    public static func string(_ bytes: some Collection<UInt8>) -> String {
        bytes.map { hex($0) }.joined(separator: ":")
    }

    /// Upper-case hex digits with separators removed, for comparisons. Returns
    /// nil if anything other than hex digits and the separators ":-. " remain.
    public static func normalizedHex(_ text: String) -> String? {
        var digits = ""
        for character in text.uppercased() {
            if character.isHexDigit {
                digits.append(character)
            } else if !":-. ".contains(character) {
                return nil
            }
        }
        return digits.isEmpty ? nil : digits
    }

    /// True for a locally administered address (bit 0x02 of the first octet),
    /// usually a randomized MAC.
    public static func isLocallyAdministered(_ bytes: some Collection<UInt8>) -> Bool {
        guard let first = bytes.first else { return false }
        return first & 0x02 != 0
    }

    private static func hex(_ byte: UInt8) -> String {
        let digits = Array("0123456789ABCDEF")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
    }
}
