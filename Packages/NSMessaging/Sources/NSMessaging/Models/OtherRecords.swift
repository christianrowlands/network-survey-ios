/// NS Messaging `BluetoothRecord` (MQTT topic `bluetooth_message`).
public typealias BluetoothRecord = NSRecord<BluetoothRecordData>
/// NS Messaging `DeviceStatus` (MQTT topic `device_status_message`).
public typealias DeviceStatus = NSRecord<DeviceStatusData>

public struct BluetoothRecordData: NSCommonData {
    public static let messageType = "BluetoothRecord"

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
    public var signalStrength: Float?
    public var txPower: Float?
    public var technology = BluetoothTechnology.unknown
    public var supportedTechnologies = BluetoothSupportedTechnologies.unknown
    public var otaDeviceName = ""
    public var channel: Int32?
    public var addressType = BluetoothAddressType.unknown
    public var deviceClass = ""
    public var serviceUuids: [String] = []
    /// Hexadecimal, lowercase, no leading zeros ("4c").
    public var companyId = ""
    /// The manufacturer specific data, company ID included, as lowercase hex.
    public var mfgData = ""

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
            .floatValue(12, "signalStrength", \.signalStrength),
            .floatValue(13, "txPower", \.txPower),
            .enumeration(14, "technology", \.technology),
            .enumeration(15, "supportedTechnologies", \.supportedTechnologies),
            .string(16, "otaDeviceName", \.otaDeviceName),
            .int32Value(17, "channel", \.channel),
            .enumeration(18, "addressType", \.addressType),
            .string(19, "deviceClass", \.deviceClass),
            .stringList(20, "serviceUuids", \.serviceUuids),
            .string(21, "companyId", \.companyId),
            .string(22, "mfgData", \.mfgData),
            .uint32(30, "locationAge", \.locationAge),
            .float(55, "speed", \.speed),
        ]
    }
}

public struct DeviceStatusData: NSCommonData {
    public static let messageType = "DeviceStatus"

    public var deviceSerialNumber = ""
    public var deviceName = ""
    public var deviceTime = ""
    public var latitude = 0.0
    public var longitude = 0.0
    public var altitude: Float = 0
    public var batteryLevelPercent: Int32?
    public var deviceModel = ""
    public var accuracy: Int32 = 0
    public var error: DeviceStatusError?
    public var mdmOverride: Bool?
    public var appVersion = ""
    public var missionId = ""
    public var recordNumber: Int32 = 0
    public var gnssLatitude = 0.0
    public var gnssLongitude = 0.0
    public var gnssAltitude: Float = 0
    public var gnssAccuracy: Int32 = 0
    public var networkLatitude = 0.0
    public var networkLongitude = 0.0
    public var networkAltitude: Float = 0
    public var networkAccuracy: Int32 = 0
    public var gnssAge: UInt32 = 0
    public var networkAge: UInt32 = 0
    /// Only ever true; leave nil otherwise (NS Messaging forbids an explicit false).
    public var mockLocation: Bool?
    public var locationAge: UInt32 = 0
    public var speed: Float = 0

    public init() {}

    public static var fields: [NSField<Self>] {
        [
            .string(1, "deviceSerialNumber", \.deviceSerialNumber),
            .string(2, "deviceName", \.deviceName),
            .string(3, "deviceTime", \.deviceTime),
            .double(4, "latitude", \.latitude),
            .double(5, "longitude", \.longitude),
            .float(6, "altitude", \.altitude),
            .int32Value(7, "batteryLevelPercent", \.batteryLevelPercent),
            .string(8, "deviceModel", \.deviceModel),
            .int32(9, "accuracy", \.accuracy),
            .deviceError(10, "error", \.error),
            .boolValue(11, "mdmOverride", \.mdmOverride),
            .string(12, "appVersion", \.appVersion),
            .string(13, "missionId", \.missionId),
            .int32(14, "recordNumber", \.recordNumber),
            .double(15, "gnssLatitude", \.gnssLatitude),
            .double(16, "gnssLongitude", \.gnssLongitude),
            .float(17, "gnssAltitude", \.gnssAltitude),
            .int32(18, "gnssAccuracy", \.gnssAccuracy),
            .double(19, "networkLatitude", \.networkLatitude),
            .double(20, "networkLongitude", \.networkLongitude),
            .float(21, "networkAltitude", \.networkAltitude),
            .int32(22, "networkAccuracy", \.networkAccuracy),
            .uint32(23, "gnssAge", \.gnssAge),
            .uint32(24, "networkAge", \.networkAge),
            .boolValue(25, "mockLocation", \.mockLocation),
            .uint32(30, "locationAge", \.locationAge),
            .float(55, "speed", \.speed),
        ]
    }
}

extension DeviceStatus {
    /// A heartbeat for the phone. `gnss` is an extra position from a board GPS
    /// receiver, reported in the `gnss*` fields for comparison.
    public init(
        context: RecordContext, deviceModel: String, appVersion: String,
        batteryLevelPercent: Int32? = nil, gnss: LocationFix? = nil, errorMessage: String? = nil
    ) {
        var data = DeviceStatusData()
        data.apply(context)
        data.deviceModel = deviceModel
        data.appVersion = appVersion
        data.batteryLevelPercent = batteryLevelPercent
        if let errorMessage { data.error = DeviceStatusError(errorMessage: errorMessage) }
        if let gnss {
            data.gnssLatitude = gnss.latitude
            data.gnssLongitude = gnss.longitude
            data.gnssAltitude = Float(gnss.altitude ?? 0)
            data.gnssAccuracy = gnss.horizontalAccuracy.map(DeviceStatusData.roundAccuracy) ?? 0
            data.gnssAge = DeviceStatusData.ageMs(of: gnss.timestamp, at: context.deviceTime)
        }
        self.init(data: data)
    }
}
