/// NS Messaging `WatchlistMatch` (MQTT topic `watchlist_match_message`): a
/// watched network was seen. One message per appearance, not per scan.
public typealias WatchlistMatch = NSRecord<WatchlistMatchData>
/// NS Messaging `WatchlistEntryUpdate` (MQTT topic `watchlist_entry_message`):
/// the device's whole watchlist, sent on connect and on every change.
public typealias WatchlistEntryUpdate = NSRecord<WatchlistEntryUpdateData>

/// How an entry's SSID and BSSID are compared. Only EXACT exists (trimmed,
/// case-insensitive equality).
public enum WatchlistMatchType: String, NSEnum {
    case unknown = "UNKNOWN", exact = "EXACT"
}

/// Which field of an entry matched. BOTH is reserved; the Android app reports
/// SSID when the entry has one, otherwise BSSID.
public enum WatchlistMatchField: String, NSEnum {
    case unknown = "UNKNOWN", ssid = "SSID", bssid = "BSSID", both = "BOTH"
}

/// Every message is a SNAPSHOT of the full list.
public enum WatchlistChangeType: String, NSEnum {
    case unknown = "UNKNOWN", snapshot = "SNAPSHOT"
}

public struct WatchlistMatchData: NSCommonData {
    public static let messageType = "WatchlistMatch"

    public var deviceSerialNumber = ""
    public var deviceName = ""
    public var deviceTime = ""
    public var latitude = 0.0
    public var longitude = 0.0
    public var altitude: Float = 0
    public var missionId = ""
    public var recordNumber: Int32 = 0
    public var accuracy: Int32 = 0
    public var locationAge: UInt32 = 0
    public var speed: Float = 0
    public var entryUuid = ""
    public var label = ""
    public var matchType = WatchlistMatchType.unknown
    public var matchedField = WatchlistMatchField.unknown
    public var ssid = ""
    public var bssid = ""
    public var signalStrength: Float?

    public init() {}

    public static var fields: [NSField<Self>] {
        [
            .string(1, "deviceSerialNumber", \.deviceSerialNumber),
            .string(2, "deviceName", \.deviceName),
            .string(3, "deviceTime", \.deviceTime),
            .double(4, "latitude", \.latitude),
            .double(5, "longitude", \.longitude),
            .float(6, "altitude", \.altitude),
            .string(7, "missionId", \.missionId),
            .int32(8, "recordNumber", \.recordNumber),
            .int32(9, "accuracy", \.accuracy),
            .uint32(10, "locationAge", \.locationAge),
            .float(11, "speed", \.speed),
            .string(12, "entryUuid", \.entryUuid),
            .string(13, "label", \.label),
            .enumeration(14, "matchType", \.matchType),
            .enumeration(15, "matchedField", \.matchedField),
            .string(16, "ssid", \.ssid),
            .string(17, "bssid", \.bssid),
            .floatValue(18, "signalStrength", \.signalStrength),
        ]
    }
}

public struct WatchlistEntryUpdateData: NSRecordData {
    public static let messageType = "WatchlistEntryUpdate"

    public var deviceSerialNumber = ""
    public var deviceName = ""
    public var deviceTime = ""
    public var missionId = ""
    /// Device-wide and increasing: a consumer keeps the list from the highest
    /// sequence it has seen. A uint64, so JSON carries it as a string.
    public var messageSequence: UInt64 = 0
    public var changeType = WatchlistChangeType.unknown
    public var entries: [WatchlistEntryMessage] = []

    public init() {}

    public static var fields: [NSField<Self>] {
        [
            .string(1, "deviceSerialNumber", \.deviceSerialNumber),
            .string(2, "deviceName", \.deviceName),
            .string(3, "deviceTime", \.deviceTime),
            .string(4, "missionId", \.missionId),
            .uint64(5, "messageSequence", \.messageSequence),
            .enumeration(6, "changeType", \.changeType),
            .messageList(7, "entries", \.entries),
        ]
    }
}

/// NS Messaging `WatchlistEntry`, one entry of a `WatchlistEntryUpdate`.
public struct WatchlistEntryMessage: NSMessageData {
    public var entryUuid = ""
    public var label = ""
    /// Left out when the entry does not watch by SSID.
    public var ssid: String?
    /// Left out when the entry does not watch by BSSID.
    public var bssid: String?
    public var matchType = WatchlistMatchType.unknown
    /// A wrapper, so `false` is still sent.
    public var enabled: Bool?
    public var cooldownSeconds: Int32 = 0
    public var createdAt = ""
    public var updatedAt = ""

    public init() {}

    public static var fields: [NSField<Self>] {
        [
            .string(1, "entryUuid", \.entryUuid),
            .string(2, "label", \.label),
            .stringValue(3, "ssid", \.ssid),
            .stringValue(4, "bssid", \.bssid),
            .enumeration(5, "matchType", \.matchType),
            .boolValue(6, "enabled", \.enabled),
            .int32(7, "cooldownSeconds", \.cooldownSeconds),
            .string(8, "createdAt", \.createdAt),
            .string(9, "updatedAt", \.updatedAt),
        ]
    }
}

extension NSRecord where Payload == WatchlistEntryUpdateData {
    /// A copy with `deviceName` set, as the MQTT destination sends it.
    public func stamped(deviceName: String?) -> NSRecord {
        guard let deviceName, !deviceName.isEmpty else { return self }
        var copy = self
        copy.data.deviceName = deviceName
        return copy
    }
}
