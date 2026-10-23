import Foundation
import GRDB

/// One survey session as stored.
public struct SessionRow: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "session"

    public var id: String
    public var missionId: String
    public var startedAt: Date
    public var stoppedAt: Date?
    public var deviceSerialNumber: String
    public var deviceName: String
    public var wifiAP: Bool
    public var wifiClient: Bool
    public var ble: Bool
    public var rawFrames: Bool
    /// Records stored.
    public var recordCount: Int
    /// Records dropped by privacy zones or the ignore list.
    public var filteredCount: Int
    /// Next record number per message type (JSON), for resume.
    public var recordNumbers: String? = nil
}

/// Fields every entity row has.
public protocol SurveyEntity: Sendable {
    var sessionId: String { get }
    var firstSeen: Date { get }
    var lastSeen: Date { get }
    var observationCount: Int { get }
    var frameCount: Int { get }
    var rssiLast: Int { get }
    var rssiMax: Int { get }
    var lastBoardId: String { get }
    var bestRssi: Int? { get }
    var bestLatitude: Double? { get }
    var bestLongitude: Double? { get }
}

public struct AccessPointRow: Codable, Sendable, Equatable, FetchableRecord, TableRecord, SurveyEntity {
    public static let databaseTableName = "accessPoint"

    public var sessionId: String
    public var bssid: String
    /// Decoded leniently; nil when hidden.
    public var ssid: String?
    public var ssidHidden: Bool
    /// `NSBBand` raw value.
    public var band: Int
    public var channel: Int
    public var frequencyMhz: Int
    /// `NSBSecurityType` raw value.
    public var security: Int
    public var groupCipher: Int
    /// Comma-separated cipher suite selectors.
    public var pairwiseCiphers: String
    /// Comma-separated AKM suite selectors.
    public var akmSuites: String
    public var channelWidth: Int
    public var phyFlags: Int
    public var wps: Bool
    public var passpoint: Bool
    public var beaconIntervalTu: Int?
    public var stationCount: Int?
    public var channelUtilization: Int?
    public var randomized: Bool
    public var firstSeen: Date
    public var lastSeen: Date
    public var observationCount: Int
    public var frameCount: Int
    public var rssiLast: Int
    public var rssiMax: Int
    public var lastBoardId: String
    public var bestRssi: Int?
    public var bestLatitude: Double?
    public var bestLongitude: Double?
}

public struct ClientRow: Codable, Sendable, Equatable, FetchableRecord, TableRecord, SurveyEntity {
    public static let databaseTableName = "client"

    public var sessionId: String
    public var mac: String
    public var randomized: Bool
    public var associatedBssid: String?
    /// `NSBClientSource` bits seen so far.
    public var sourceFlags: Int
    public var band: Int
    public var channel: Int
    public var firstSeen: Date
    public var lastSeen: Date
    public var observationCount: Int
    public var frameCount: Int
    public var rssiLast: Int
    public var rssiMax: Int
    public var lastBoardId: String
    public var bestRssi: Int?
    public var bestLatitude: Double?
    public var bestLongitude: Double?
}

/// One (client, SSID) pair from probe requests: an entry of the client's
/// preferred network list. An empty SSID is a wildcard probe.
public struct ProbeRow: Codable, Sendable, Equatable, FetchableRecord, TableRecord, SurveyEntity {
    public static let databaseTableName = "probe"

    public var sessionId: String
    public var clientMac: String
    public var ssid: String
    public var randomized: Bool
    public var band: Int
    public var channel: Int
    public var firstSeen: Date
    public var lastSeen: Date
    public var observationCount: Int
    public var frameCount: Int
    public var rssiLast: Int
    public var rssiMax: Int
    public var lastBoardId: String
    public var bestRssi: Int?
    public var bestLatitude: Double?
    public var bestLongitude: Double?

    public var isWildcard: Bool { ssid.isEmpty }
}

public struct BLEDeviceRow: Codable, Sendable, Equatable, FetchableRecord, TableRecord, SurveyEntity {
    public static let databaseTableName = "bleDevice"

    public var sessionId: String
    public var address: String
    /// `NSBBleAddressType` raw value.
    public var addressType: Int
    /// A random (non-public) address.
    public var randomized: Bool
    public var name: String?
    public var companyId: Int?
    public var txPower: Int?
    public var advType: Int
    /// Raw AD structures of the last advertisement.
    public var advData: Data
    public var firstSeen: Date
    public var lastSeen: Date
    public var observationCount: Int
    public var frameCount: Int
    public var rssiLast: Int
    public var rssiMax: Int
    public var lastBoardId: String
    public var bestRssi: Int?
    public var bestLatitude: Double?
    public var bestLongitude: Double?
}

public enum ObservationKind: String, Codable, Sendable, CaseIterable {
    case ap, client, probe, ble
}

public struct ObservationRow: Codable, Sendable, Equatable, FetchableRecord, TableRecord {
    public static let databaseTableName = "observation"

    public var id: Int64
    public var sessionId: String
    public var kind: ObservationKind
    public var identity: String
    public var boardId: String
    public var time: Date
    public var rssi: Int
    public var rssiMax: Int
    public var channel: Int
    public var frequencyMhz: Int
    public var band: Int
    public var ssid: String?
    public var bssid: String?
    public var latitude: Double?
    public var longitude: Double?
    public var accuracy: Double?
}

/// A period when a board was disconnected during a session.
public struct GapEventRow: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "gapEvent"

    public var id: Int64?
    public var sessionId: String
    public var boardId: String
    public var startedAt: Date
    public var endedAt: Date?
    public var reason: String
    /// Records or notifications lost, on the zero-length loss rows.
    public var missedNotifications: Int

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct TrackPointRow: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "trackPoint"

    public var id: Int64?
    public var sessionId: String
    public var time: Date
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?
    public var accuracy: Double?
    public var speed: Double?
    public var source: String
}
