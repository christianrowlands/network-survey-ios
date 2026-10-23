import Foundation

/// Mission IDs in the Network Survey Android app's format:
/// "NS <deviceId> <yyyyMMdd-HHmmss>", with the start time in local time.
/// On iOS the device ID is the install ID's first 8 hex digits, the same value
/// as `DeviceIdentity.deviceSerialNumber`.
public enum MissionID {
    public static let prefix = "NS "

    public static func make(installID: UUID, startedAt: Date, timeZone: TimeZone = .current) -> String {
        "\(prefix)\(DeviceIdentity.shortID(installID)) \(timestamp(startedAt, timeZone: timeZone))"
    }

    /// "NS DEMO <yyyyMMdd-HHmmss>" for a survey that includes the simulated
    /// Demo board, so its data is easy to tell apart.
    public static func makeDemo(startedAt: Date, timeZone: TimeZone = .current) -> String {
        "\(prefix)DEMO \(timestamp(startedAt, timeZone: timeZone))"
    }

    /// The `yyyyMMdd-HHmmss` stamp used in mission IDs and file names.
    public static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02d-%02d%02d%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
    }
}
