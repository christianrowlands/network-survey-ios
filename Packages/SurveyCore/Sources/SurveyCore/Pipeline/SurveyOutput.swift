import BoardKit
import BoardProtocol
import Destinations
import Foundation

/// Facts about the app and phone that some records and files carry.
public struct AppInfo: Sendable, Equatable {
    /// Hardware model identifier, for example "iPhone17,3".
    public var deviceModel: String
    /// For example "18.0".
    public var osVersion: String
    public var appVersion: String

    public init(deviceModel: String = DeviceModel.identifier(), osVersion: String = AppInfo.currentOSVersion, appVersion: String) {
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.appVersion = appVersion
    }

    public static var currentOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }
}

/// Session facts every destination needs when it starts.
public struct SessionContext: Sendable, Equatable {
    public var sessionID: String
    public var missionId: String
    public var startedAt: Date
    public var deviceSerialNumber: String
    public var deviceName: String
    public var plan: SurveyPlan
    public var app: AppInfo
    /// The session's folder for files, `<files root>/Surveys/<yyyyMMdd-HHmmss>/`.
    public var directory: URL
    /// The zone file names and record times are written in (local, as on Android).
    public var timeZone: TimeZone = .current
}

/// What the user chose to survey and where it goes, fixed for a session.
public struct SurveyPlan: Sendable, Equatable, Codable {
    public var wifiAP: Bool
    /// Client (station) and probe request records.
    public var wifiClient: Bool
    public var ble: Bool
    public var rawFrames: Bool
    public var logFiles: Bool
    public var mqtt: Bool
    public var grpc: Bool
    public var nsAnalytics: Bool

    public init(
        wifiAP: Bool = true, wifiClient: Bool = true, ble: Bool = false, rawFrames: Bool = false,
        logFiles: Bool = true, mqtt: Bool = false, grpc: Bool = false, nsAnalytics: Bool = false
    ) {
        self.wifiAP = wifiAP
        self.wifiClient = wifiClient
        self.ble = ble
        self.rawFrames = rawFrames
        self.logFiles = logFiles
        self.mqtt = mqtt
        self.grpc = grpc
        self.nsAnalytics = nsAnalytics
    }

    public init(settings: SettingsStore) {
        self.init(
            wifiAP: settings[Settings.surveyWifiAP], wifiClient: settings[Settings.surveyWifiClient],
            ble: settings[Settings.surveyBLE], rawFrames: settings[Settings.surveyRawFrames],
            logFiles: settings[Settings.destinationLogFiles], mqtt: settings[Settings.destinationMQTT],
            grpc: settings[Settings.destinationGRPC], nsAnalytics: settings[Settings.destinationNSAnalytics]
        )
    }

    public var surveysAnything: Bool { wifiAP || wifiClient || ble }
}

/// NS Messaging record types; each has its own recordNumber sequence.
public enum MessageType: String, Sendable, CaseIterable, Codable {
    case wifiBeacon
    case wifiProbeRequest
    /// Experimental station (client) record.
    case wifiStation
    case bluetooth
    case deviceStatus
}

/// The fields NS Messaging stamps on every record (RecordContext in NSMessaging).
public struct OutputContext: Sendable, Equatable {
    public var deviceSerialNumber: String
    public var deviceName: String
    public var missionId: String
    public var recordNumber: Int
    public var deviceTime: Date
    public var location: LocationSample?
    /// The board that produced the record; nil for device status.
    public var boardID: String?
}

/// Device status details, sent every `device_status_scan_interval_seconds`.
public struct DeviceStatusInfo: Sendable, Equatable {
    /// 0 to 100, nil when unknown.
    public var batteryLevelPercent: Int?
    public var connectedBoards: Int
    /// A board GPS fix reported beside the phone location, when both exist.
    public var boardGPS: LocationSample?
    public var deviceModel: String
    public var appVersion: String
}

/// One record leaving the pipeline for the destinations.
public struct SurveyOutput: Sendable {
    public enum Payload: Sendable {
        case accessPoint(NSBApObservation)
        case client(NSBClientObservation)
        case probe(NSBProbeObservation)
        case ble(NSBBleObservation)
        case deviceStatus(DeviceStatusInfo)
    }

    public var type: MessageType
    public var payload: Payload
    public var context: OutputContext
}

/// A raw 802.11 frame for pcapng, after the privacy filter.
public struct RawFrameOutput: Sendable {
    public var boardID: String
    public var frame: NSBRawFrame
    public var time: Date
}

/// A destination as SurveyCore drives it. Adapters wrap the Destinations
/// package implementations; tests use a recording fake.
public protocol SurveyRecordSink: Sendable {
    var name: String { get }
    func start(_ session: SessionContext) async throws
    func accept(_ records: [SurveyOutput]) async
    func acceptRaw(_ frames: [RawFrameOutput]) async
    /// Flushes and closes. Uploads that outlive the session continue on their own.
    func stop() async
    /// What the UI shows, by destination name. A sink may stand for several destinations.
    func snapshots() async -> [String: DestinationSnapshot]
}

extension SurveyRecordSink {
    public func acceptRaw(_ frames: [RawFrameOutput]) async {}
}

/// Per-session, per-message-type record numbers starting at 1, as the Network
/// Survey Android app numbers records per protocol.
public struct RecordNumbers: Sendable, Equatable {
    private var next: [MessageType: Int] = [:]

    public init(startingAfter counts: [MessageType: Int] = [:]) {
        for (type, count) in counts { next[type] = count + 1 }
    }

    public mutating func take(_ type: MessageType) -> Int {
        let number = next[type, default: 1]
        next[type] = number + 1
        return number
    }

    public func peek(_ type: MessageType) -> Int { next[type, default: 1] }

    /// Stored with the session so a resumed session continues every sequence.
    var json: String {
        let byName = Dictionary(uniqueKeysWithValues: next.map { ($0.key.rawValue, $0.value) })
        let data = (try? JSONEncoder().encode(byName)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    init?(json: String?) {
        guard let json, let byName = try? JSONDecoder().decode([String: Int].self, from: Data(json.utf8)) else { return nil }
        for (name, value) in byName {
            if let type = MessageType(rawValue: name) { next[type] = value }
        }
    }
}
