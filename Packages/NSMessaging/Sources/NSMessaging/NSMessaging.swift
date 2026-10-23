import Foundation

/// Models and JSON encoding for the NS Messaging API, plus converters from
/// board records.
public enum NSMessaging {
    /// The NS Messaging API version the models follow.
    public static let apiVersion = "2.6.0"
}

/// A position to stamp on records.
public struct LocationFix: Sendable, Equatable, Codable {
    public enum Source: String, Sendable, Codable {
        case phone
        case boardGPS
    }

    public var latitude: Double
    public var longitude: Double
    /// Meters above mean sea level.
    public var altitude: Double?
    /// Meters, radius of 68% confidence.
    public var horizontalAccuracy: Double?
    /// Meters per second.
    public var speed: Double?
    /// When the fix was taken.
    public var timestamp: Date
    public var source: Source

    public init(
        latitude: Double, longitude: Double, altitude: Double? = nil, horizontalAccuracy: Double? = nil,
        speed: Double? = nil, timestamp: Date, source: Source = .phone
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.timestamp = timestamp
        self.source = source
    }
}

/// Session and position data a converter needs besides the board record.
/// `deviceName` is not here: like the Android app, records leave it empty and
/// the MQTT and gRPC destinations stamp it.
public struct RecordContext: Sendable, Equatable {
    public var deviceSerialNumber: String
    public var missionId: String
    /// Starts at 1 per message type and session.
    public var recordNumber: Int32
    /// When the record was observed.
    public var deviceTime: Date
    public var location: LocationFix?
    /// The zone `deviceTime` is written in (the Android app uses the phone's).
    public var timeZone: TimeZone

    public init(
        deviceSerialNumber: String, missionId: String, recordNumber: Int32, deviceTime: Date,
        location: LocationFix?, timeZone: TimeZone = .current
    ) {
        self.deviceSerialNumber = deviceSerialNumber
        self.missionId = missionId
        self.recordNumber = recordNumber
        self.deviceTime = deviceTime
        self.location = location
        self.timeZone = timeZone
    }
}

/// The fields every NS Messaging payload shares.
public protocol NSCommonData: NSRecordData {
    var deviceSerialNumber: String { get set }
    var deviceName: String { get set }
    var deviceTime: String { get set }
    var latitude: Double { get set }
    var longitude: Double { get set }
    var altitude: Float { get set }
    var missionId: String { get set }
    var recordNumber: Int32 { get set }
    var accuracy: Int32 { get set }
    var locationAge: UInt32 { get set }
    var speed: Float { get set }
}

extension NSCommonData {
    /// Sets the identity, time and location fields the way the Android app does.
    public mutating func apply(_ context: RecordContext) {
        deviceSerialNumber = context.deviceSerialNumber
        deviceTime = DeviceTime.string(context.deviceTime, timeZone: context.timeZone)
        missionId = context.missionId
        recordNumber = context.recordNumber
        guard let fix = context.location else { return }
        latitude = fix.latitude
        longitude = fix.longitude
        altitude = Float(fix.altitude ?? 0)
        accuracy = fix.horizontalAccuracy.map(Self.roundAccuracy) ?? 0
        locationAge = Self.ageMs(of: fix.timestamp, at: context.deviceTime)
        // The Android app leaves out speeds under 0.1 m/s.
        if let speed = fix.speed, speed >= 0.1 { self.speed = Float(speed) }
    }

    /// Whole milliseconds from `time` to `now`, 0 if not positive.
    static func ageMs(of time: Date, at now: Date) -> UInt32 {
        func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }
        let age = ms(now) - ms(time)
        return age > 0 ? UInt32(min(age, Int64(Int32.max))) : 0
    }

    /// Rounds like the Android app: values between 0 and 0.5 become 1. Invalid
    /// (negative, as CoreLocation reports them) or unknown accuracy is 0.
    static func roundAccuracy(_ meters: Double) -> Int32 {
        guard meters > 0, meters.isFinite else { return 0 }
        if meters < 0.5 { return 1 }
        return Int32(min(Double(Float(meters)).rounded(.toNearestOrAwayFromZero), Double(Int32.max)))
    }
}

extension NSRecord where Payload: NSCommonData {
    /// A copy with `deviceName` set, as the MQTT and gRPC destinations send it.
    /// An empty name leaves the record unchanged.
    public func stamped(deviceName: String?) -> NSRecord {
        guard let deviceName, !deviceName.isEmpty else { return self }
        var copy = self
        copy.data.deviceName = deviceName
        return copy
    }
}

/// `deviceTime` text: Java `DateTimeFormatter.ISO_OFFSET_DATE_TIME` at
/// millisecond precision, for example `2026-10-22T14:03:07.12-05:00`.
public enum DeviceTime {
    public static func string(_ date: Date, timeZone: TimeZone) -> String {
        let millis = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
        let offset = timeZone.secondsFromGMT(for: date)
        let local = millis + Int64(offset) * 1000
        let days = Int64((Double(local) / 86_400_000).rounded(.down))
        let msOfDay = local - days * 86_400_000
        let (year, month, day) = civilDate(daysSinceEpoch: days)
        let seconds = msOfDay / 1000
        var text = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", year, month, day,
                          Int(seconds / 3600), Int(seconds / 60 % 60), Int(seconds % 60))
        let fraction = msOfDay % 1000
        if fraction != 0 {
            var digits = String(format: "%03d", Int(fraction))
            while digits.hasSuffix("0") { digits.removeLast() }
            text += "." + digits
        }
        if offset == 0 { return text + "Z" }
        let magnitude = abs(offset)
        text += String(format: "%@%02d:%02d", offset < 0 ? "-" : "+", magnitude / 3600, magnitude / 60 % 60)
        if magnitude % 60 != 0 { text += String(format: ":%02d", magnitude % 60) }
        return text
    }

    /// Proleptic Gregorian date from days since 1970-01-01 (H. Hinnant's algorithm).
    private static func civilDate(daysSinceEpoch: Int64) -> (Int, Int, Int) {
        let z = daysSinceEpoch + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        return (Int(year), Int(month), Int(day))
    }
}
