import BoardProtocol
import Foundation
import NSMessaging
import Testing
@testable import Destinations

enum Fixtures {
    struct Missing: Error { let path: String }

    static func url(_ path: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(path)", withExtension: nil) else { throw Missing(path: path) }
        return url
    }

    static func data(_ path: String) throws -> Data { try Data(contentsOf: url(path)) }
    static func text(_ path: String) throws -> String { try String(contentsOf: url(path), encoding: .utf8) }

    /// Writes what a test produced, so a new golden can be checked before it is committed.
    static func saveActual(_ data: Data, as name: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("destinations-actual")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent(name))
    }
}

enum Samples {
    static let utc = TimeZone(identifier: "UTC")!
    static let start = Date(timeIntervalSince1970: 1_792_000_980) // 2026-10-14 18:03:00 UTC

    static func session(_ directory: URL, deviceName: String = "Field kit 2") -> SessionInfo {
        SessionInfo(
            missionId: "NS 8C2E1F7A 20261014-180300", startedAt: start,
            directory: directory, deviceSerialNumber: "8C2E1F7A", deviceName: deviceName,
            deviceModel: "iPhone17,3", osVersion: "18.0", appVersion: "1.0.0", timeZone: utc
        )
    }

    static func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("destinations-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func context(_ number: Int32, location: Bool = true) -> RecordContext {
        RecordContext(
            deviceSerialNumber: "8C2E1F7A",
            missionId: "NS 8C2E1F7A 20261014-180300",
            recordNumber: number, deviceTime: start.addingTimeInterval(7.25),
            location: location ? LocationFix(latitude: 38.889484, longitude: -77.035278, altitude: 21.3,
                                             horizontalAccuracy: 4.6, speed: 1.25,
                                             timestamp: start.addingTimeInterval(6.45)) : nil,
            timeZone: utc
        )
    }

    static var ap: NSBApObservation {
        .with {
            $0.channel = 36
            $0.frequencyMhz = 5180
            $0.band = .ghz5
            $0.bssid = Data([0x02, 0x00, 0x5E, 0x00, 0x53, 0x01])
            $0.ssid = Data("ExampleNet".utf8)
            $0.rssiMax = -48
            $0.noiseFloorDbm = -95
            $0.beaconIntervalTu = 100
            $0.capabilityInfo = 0x0011
            $0.security = .wpa2Wpa3
            $0.groupCipher = 0x000FAC04
            $0.pairwiseCiphers = [0x000FAC04]
            $0.akmSuites = [0x000FAC02, 0x000FAC08]
            $0.phyFlags = 7
            $0.channelWidth = .mhz80
            $0.wps = true
            $0.supportedRates = Data([0x8C, 0x12, 0x98, 0x24, 0xB0, 0x48, 0x60, 0x6C])
        }
    }

    static var probe: NSBProbeObservation {
        .with {
            $0.channel = 6
            $0.frequencyMhz = 2437
            $0.band = .ghz24
            $0.clientMac = Data([0x06, 0x1A, 0x2B, 0x3C, 0x4D, 0x5E])
            $0.ssid = Data("Cafe-Guest, upstairs".utf8)
            $0.rssiMax = -62
            $0.count = 3
            $0.locallyAdministered = true
            $0.destinationAddress = Data(repeating: 0xFF, count: 6)
            $0.bssid = Data(repeating: 0xFF, count: 6)
            $0.phyFlags = 1
        }
    }

    static var client: NSBClientObservation {
        .with {
            $0.channel = 11
            $0.frequencyMhz = 2462
            $0.band = .ghz24
            $0.clientMac = Data([0x0A, 0x11, 0x22, 0x33, 0x44, 0x55])
            $0.associatedBssid = Data([0x02, 0x00, 0x5E, 0x00, 0x53, 0x02])
            $0.rssiMax = -55
            $0.noiseFloorDbm = -92
            $0.frameCount = 14
            $0.sourceFlags = 3
            $0.locallyAdministered = true
        }
    }

    static var ble: NSBBleObservation {
        .with {
            $0.channel = 37
            $0.address = Data([0xC2, 0x00, 0x5E, 0x00, 0x53, 0x10])
            $0.addressType = .random
            $0.rssiMax = -71
            $0.advData = Data([0x02, 0x01, 0x06, 0x07, 0xFF, 0x4C, 0x00, 0x12, 0x02, 0x00, 0x03])
            $0.localName = Data("Example Tag".utf8)
            $0.companyID = 0x004C
        }
    }

    static func apRecord(_ number: Int32 = 1, board: String = "NS-1A2B") -> SurveyRecord {
        SurveyRecord(boardID: board, kind: .ap(WifiBeaconRecord(ap: ap, context: context(number)), ap))
    }

    static func probeRecord(_ number: Int32 = 1, board: String = "NS-1A2B") -> SurveyRecord {
        SurveyRecord(boardID: board, kind: .probe(WifiProbeRequestRecord(probe: probe, context: context(number)), probe))
    }

    static func clientRecord(_ number: Int32 = 1, board: String = "NS-1A2B") -> SurveyRecord {
        SurveyRecord(boardID: board, kind: .client(WifiStationRecord(client: client, context: context(number)), client))
    }

    static func bleRecord(_ number: Int32 = 1, board: String = "NS-3C4D") -> SurveyRecord {
        SurveyRecord(boardID: board, kind: .ble(BluetoothRecord(ble: ble, context: context(number)), ble))
    }

    static func statusRecord(_ number: Int32 = 1) -> SurveyRecord {
        SurveyRecord(boardID: "", kind: .deviceStatus(DeviceStatus(
            context: context(number), deviceModel: "iPhone17,3", appVersion: "1.0.0", batteryLevelPercent: 80
        )))
    }
}
