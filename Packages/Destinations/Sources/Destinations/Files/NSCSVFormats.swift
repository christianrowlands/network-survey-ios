import BoardProtocol
import Foundation
import NSMessaging

/// The NS CSV formats. Wi-Fi (0.4.0) and Bluetooth (0.3.0) have exactly the
/// columns and value formatting of the Network Survey Android app; the client
/// and probe formats (0.1.0) are new in the same style (docs/csv-formats.md).
enum NSCSVFormat: CaseIterable {
    case wifi, bluetooth, client, probe

    var filePrefix: String {
        switch self {
        case .wifi: "craxiom-wifi-"
        case .bluetooth: "craxiom-bluetooth-"
        case .client: "craxiom-wifi-client-"
        case .probe: "craxiom-wifi-probe-"
        }
    }

    var version: String {
        switch self {
        case .wifi: "0.4.0"
        case .bluetooth: "0.3.0"
        case .client, .probe: "0.1.0"
        }
    }

    static let common = ["deviceTime", "latitude", "longitude", "altitude", "speed", "accuracy", "missionId", "recordNumber"]

    var headers: [String] {
        switch self {
        case .wifi:
            Self.common + [
                "sourceAddress", "destinationAddress", "bssid", "beaconInterval", "serviceSetType", "ssid",
                "supportedRates", "extendedSupportedRates", "cipherSuites", "akmSuites", "encryptionType", "wps",
                "channel", "frequencyMhz", "signalStrength", "snr", "nodeType", "standard", "passpoint", "bandwidth",
                "deviceSerialNumber", "locationAge",
            ]
        case .bluetooth:
            Self.common + [
                "sourceAddress", "destinationAddress", "signalStrength", "txPower", "technology",
                "supportedTechnologies", "otaDeviceName", "channel", "deviceSerialNumber", "locationAge",
                "addressType", "deviceClass", "serviceUuids", "companyId", "mfgData",
            ]
        case .client:
            Self.common + [
                "sourceAddress", "bssid", "channel", "frequencyMhz", "signalStrength", "snr", "frameCount",
                "frameTypes", "locallyAdministered", "boardId", "deviceSerialNumber", "locationAge",
            ]
        case .probe:
            Self.common + [
                "sourceAddress", "destinationAddress", "bssid", "ssid", "channel", "frequencyMhz", "signalStrength",
                "snr", "standard", "probeCount", "locallyAdministered", "boardId", "deviceSerialNumber", "locationAge",
            ]
        }
    }
}

/// Row values, formatted the way the Android CSV loggers format them.
enum NSCSVRow {
    static func optional<T>(_ value: T?, _ format: (T) -> String) -> String {
        value.map(format) ?? ""
    }

    static func float(_ value: Float) -> String { JavaNumberFormat.string(value) }

    static func common(_ data: some NSCommonData) -> [String] {
        [
            data.deviceTime,
            JavaNumberFormat.fixed(data.latitude, decimals: 6),
            JavaNumberFormat.fixed(data.longitude, decimals: 6),
            JavaNumberFormat.ceilingTwoDecimals(Double(data.altitude)),
            JavaNumberFormat.ceilingTwoDecimals(Double(data.speed)),
            JavaNumberFormat.ceilingTwoDecimals(Double(data.accuracy)),
            data.missionId,
            String(data.recordNumber),
        ]
    }

    static func locationAge(_ age: UInt32) -> String { age == 0 ? "" : String(age) }

    static func name<E: NSEnum>(orEmpty value: E) -> String { value == .unknown ? "" : value.rawValue }

    static func wifi(_ data: WifiBeaconRecordData) -> [String] {
        common(data) + [
            data.sourceAddress,
            data.destinationAddress,
            data.bssid,
            optional(data.beaconInterval) { String($0) },
            name(orEmpty: data.serviceSetType),
            data.ssid,
            data.supportedRates,
            data.extendedSupportedRates,
            data.cipherSuites.map(\.rawValue).joined(separator: ";"),
            data.akmSuites.map(\.rawValue).joined(separator: ";"),
            data.encryptionType.rawValue,
            optional(data.wps) { String($0) },
            optional(data.channel) { String($0) },
            optional(data.frequencyMhz) { String($0) },
            optional(data.signalStrength, float),
            optional(data.snr, float),
            name(orEmpty: data.nodeType),
            data.standard.rawValue,
            optional(data.passpoint) { String($0) },
            data.bandwidth.rawValue,
            data.deviceSerialNumber,
            locationAge(data.locationAge),
        ]
    }

    static func bluetooth(_ data: BluetoothRecordData) -> [String] {
        common(data) + [
            data.sourceAddress,
            data.destinationAddress,
            optional(data.signalStrength, float),
            optional(data.txPower, float),
            data.technology.rawValue,
            data.supportedTechnologies.rawValue,
            data.otaDeviceName,
            optional(data.channel) { String($0) },
            data.deviceSerialNumber,
            locationAge(data.locationAge),
            data.addressType.rawValue,
            data.deviceClass,
            data.serviceUuids.joined(separator: ";"),
            data.companyId,
            data.mfgData,
        ]
    }

    static func client(_ data: WifiStationRecordData, boardID: String) -> [String] {
        common(data) + [
            data.sourceAddress,
            data.bssid,
            optional(data.channel) { String($0) },
            optional(data.frequencyMhz) { String($0) },
            optional(data.signalStrength, float),
            optional(data.snr, float),
            optional(data.frameCount) { String($0) },
            data.frameTypes.map(\.rawValue).joined(separator: ";"),
            optional(data.locallyAdministered) { String($0) },
            boardID,
            data.deviceSerialNumber,
            locationAge(data.locationAge),
        ]
    }

    static func probe(_ data: WifiProbeRequestRecordData, _ probe: NSBProbeObservation, boardID: String) -> [String] {
        common(data) + [
            data.sourceAddress,
            data.destinationAddress,
            data.bssid,
            data.ssid,
            optional(data.channel) { String($0) },
            optional(data.frequencyMhz) { String($0) },
            optional(data.signalStrength, float),
            optional(data.snr, float),
            data.standard.rawValue,
            String(probe.count),
            String(probe.locallyAdministered),
            boardID,
            data.deviceSerialNumber,
            locationAge(data.locationAge),
        ]
    }
}
