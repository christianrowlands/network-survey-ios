/// NS Messaging `WifiBeaconRecord` (MQTT topic `80211_beacon_message`).
public typealias WifiBeaconRecord = NSRecord<WifiBeaconRecordData>
/// NS Messaging `WifiProbeRequestRecord` (MQTT topic `80211_probe_request_message`).
public typealias WifiProbeRequestRecord = NSRecord<WifiProbeRequestRecordData>
/// NS Messaging `WifiClientRecord` (MQTT topic `80211_client_message`), new in 2.7.0.
public typealias WifiClientRecord = NSRecord<WifiClientRecordData>

public struct WifiBeaconRecordData: NSCommonData {
    public static let messageType = "WifiBeaconRecord"

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
    public var sourceAddress = ""
    public var destinationAddress = ""
    public var bssid = ""
    public var beaconInterval: Int32?
    public var serviceSetType = ServiceSetType.unknown
    public var ssid = ""
    public var supportedRates = ""
    public var extendedSupportedRates = ""
    public var cipherSuites: [CipherSuite] = []
    public var akmSuites: [AkmSuite] = []
    public var encryptionType = EncryptionType.unknown
    public var wps: Bool?
    public var passpoint: Bool?
    public var bandwidth = WifiBandwidth.unknown
    public var channel: Int32?
    public var frequencyMhz: Int32?
    public var signalStrength: Float?
    public var snr: Float?
    public var nodeType = NodeType.unknown
    public var standard = WifiStandard.unknown

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
            .string(10, "sourceAddress", \.sourceAddress),
            .string(11, "destinationAddress", \.destinationAddress),
            .string(12, "bssid", \.bssid),
            .int32Value(13, "beaconInterval", \.beaconInterval),
            .enumeration(14, "serviceSetType", \.serviceSetType),
            .string(15, "ssid", \.ssid),
            .string(16, "supportedRates", \.supportedRates),
            .string(17, "extendedSupportedRates", \.extendedSupportedRates),
            .enumList(18, "cipherSuites", \.cipherSuites),
            .enumList(19, "akmSuites", \.akmSuites),
            .enumeration(20, "encryptionType", \.encryptionType),
            .boolValue(21, "wps", \.wps),
            .int32Value(22, "channel", \.channel),
            .int32Value(23, "frequencyMhz", \.frequencyMhz),
            .floatValue(24, "signalStrength", \.signalStrength),
            .floatValue(25, "snr", \.snr),
            .enumeration(26, "nodeType", \.nodeType),
            .enumeration(27, "standard", \.standard),
            .boolValue(28, "passpoint", \.passpoint),
            .enumeration(29, "bandwidth", \.bandwidth),
            .uint32(40, "locationAge", \.locationAge),
            .float(55, "speed", \.speed),
        ]
    }
}

public struct WifiProbeRequestRecordData: NSCommonData {
    public static let messageType = "WifiProbeRequestRecord"

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
    public var sourceAddress = ""
    public var destinationAddress = ""
    public var bssid = ""
    public var ssid = ""
    public var channel: Int32?
    public var frequencyMhz: Int32?
    public var signalStrength: Float?
    public var snr: Float?
    public var nodeType = NodeType.unknown
    public var standard = WifiStandard.unknown

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
            .string(10, "sourceAddress", \.sourceAddress),
            .string(11, "destinationAddress", \.destinationAddress),
            .string(12, "bssid", \.bssid),
            .string(13, "ssid", \.ssid),
            .int32Value(14, "channel", \.channel),
            .int32Value(15, "frequencyMhz", \.frequencyMhz),
            .floatValue(16, "signalStrength", \.signalStrength),
            .floatValue(17, "snr", \.snr),
            .enumeration(18, "nodeType", \.nodeType),
            .enumeration(19, "standard", \.standard),
            .uint32(30, "locationAge", \.locationAge),
            .float(55, "speed", \.speed),
        ]
    }
}

/// One Wi-Fi client (a device that connects to an access point) seen during a
/// channel dwell. It summarizes every frame the client transmitted in that
/// window. Sent only where the user turned on client records.
public struct WifiClientRecordData: NSCommonData {
    public static let messageType = "WifiClientRecord"

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
    /// The client's MAC address.
    public var sourceAddress = ""
    /// The BSSID the client is associated with or talking to, if known.
    public var bssid = ""
    public var channel: Int32?
    public var frequencyMhz: Int32?
    public var signalStrength: Float?
    public var snr: Float?
    /// Every kind of frame received from the client during the dwell, each once.
    public var frameTypes: [ClientFrameType] = []

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
            .string(10, "sourceAddress", \.sourceAddress),
            .string(11, "bssid", \.bssid),
            .int32Value(12, "channel", \.channel),
            .int32Value(13, "frequencyMhz", \.frequencyMhz),
            .floatValue(14, "signalStrength", \.signalStrength),
            .floatValue(15, "snr", \.snr),
            .enumList(16, "frameTypes", \.frameTypes),
            .uint32(30, "locationAge", \.locationAge),
            .float(55, "speed", \.speed),
        ]
    }
}
