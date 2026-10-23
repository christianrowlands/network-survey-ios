import Foundation

/// Who produced the records: `deviceSerialNumber` is the short form of a
/// per-install UUID kept in the Keychain (iOS has no IMEI), `deviceName` is the
/// user's setting or a readable per-install default ("iPhone-12FE").
public struct DeviceIdentity: Sendable, Equatable {
    public var installID: UUID
    public var deviceName: String

    /// The install ID's first 8 hex digits, as in the mission ID ("12FE3A4B").
    public var deviceSerialNumber: String { Self.shortID(installID) }

    public init(installID: UUID, deviceName: String) {
        self.installID = installID
        self.deviceName = deviceName
    }

    /// Reads the install UUID, creating and storing it on first use, and the
    /// device name setting (falling back to `defaultName(installID:)`). Also
    /// clears stale credentials on a fresh install. `deviceModel` is kept for
    /// callers; the model goes in `AppInfo`, not the name.
    ///
    /// A new ID is only created when the Keychain says there is none. If the
    /// Keychain cannot be read (locked, background launch), a temporary ID is
    /// used for this launch and nothing is written, so the real one survives.
    public static func load(from settings: SettingsStore, deviceModel: String = DeviceModel.identifier()) -> DeviceIdentity {
        settings.clearStaleCredentialsOnFreshInstall()
        let installID: UUID
        do {
            if let stored = try settings.readSecret(Secrets.installID).flatMap(UUID.init(uuidString:)) {
                installID = stored
            } else {
                installID = UUID()
                try? settings.setSecret(installID.uuidString, for: Secrets.installID)
            }
        } catch {
            installID = UUID()
        }
        return DeviceIdentity(installID: installID, deviceName: name(settings: settings, installID: installID))
    }

    /// The device name setting as it is now, else `defaultName(installID:)`.
    /// Each survey reads it at Start, so a rename applies without a relaunch.
    public static func name(settings: SettingsStore, installID: UUID) -> String {
        let name = settings[Settings.deviceName].trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? defaultName(installID: installID) : name
    }

    /// The first 8 hex digits of the install ID, upper case: short enough to read
    /// in a mission ID and, with the start time, unique within a workspace.
    public static func shortID(_ installID: UUID) -> String {
        String(installID.uuidString.prefix(8)).uppercased()
    }

    /// "iPhone-" plus the first four hex digits of the install ID, upper case:
    /// readable, stable per install, and different between phones.
    public static func defaultName(installID: UUID) -> String {
        "iPhone-" + installID.uuidString.prefix(4).uppercased()
    }
}

public enum DeviceModel {
    /// The hardware model identifier, for example "iPhone17,3". On the
    /// simulator, the simulated model.
    public static func identifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine.isEmpty ? "iPhone" : machine
    }
}
