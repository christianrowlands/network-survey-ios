import BoardProtocol
import Foundation
import NSMessaging

/// Where survey records go: files, MQTT, gRPC or NS Analytics. Each destination
/// is configured in its initializer, started once per survey session, fed
/// batches of records and stopped at the end of the session. `accept` never
/// throws; problems show up in `snapshot()`.
public protocol Destination: Actor {
    nonisolated var kind: DestinationKind { get }
    func start(_ session: SessionInfo) async throws
    func accept(_ records: [SurveyRecord]) async
    func stop() async
    func snapshot() async -> DestinationSnapshot
}

public enum DestinationKind: String, Sendable, CaseIterable {
    case nsCSV, pcap, mqtt, grpc, nsAnalytics
}

/// The survey session the destinations work for.
public struct SessionInfo: Sendable, Equatable {
    public var missionId: String
    public var startedAt: Date
    /// The session folder for files, for example `Documents/Surveys/20261022-140300/`.
    public var directory: URL
    public var deviceSerialNumber: String
    /// The user's device name (stamped on MQTT and gRPC records).
    public var deviceName: String
    /// Hardware model identifier, for example "iPhone17,3".
    public var deviceModel: String
    /// For example "18.0".
    public var osVersion: String
    public var appVersion: String
    /// The zone used for file names (the Android app uses local time).
    public var timeZone: TimeZone

    public init(
        missionId: String, startedAt: Date, directory: URL, deviceSerialNumber: String, deviceName: String,
        deviceModel: String, osVersion: String, appVersion: String, timeZone: TimeZone = .current
    ) {
        self.missionId = missionId
        self.startedAt = startedAt
        self.directory = directory
        self.deviceSerialNumber = deviceSerialNumber
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.timeZone = timeZone
    }
}

/// A record on its way to the destinations: the NS Messaging form plus the
/// board observation it came from, which the file formats need for details NS
/// Messaging has no field for.
public struct SurveyRecord: Sendable {
    public enum Kind: Sendable {
        case ap(WifiBeaconRecord, NSBApObservation)
        case probe(WifiProbeRequestRecord, NSBProbeObservation)
        /// Experimental station record: streamed and uploaded only when enabled.
        case client(WifiStationRecord, NSBClientObservation)
        case ble(BluetoothRecord, NSBBleObservation)
        case deviceStatus(DeviceStatus)
        /// A raw 802.11 frame for pcapng, with its capture time.
        case rawFrame(NSBRawFrame, timestamp: Date)
    }

    /// The board that produced the record (empty for phone records).
    public var boardID: String
    public var kind: Kind

    public init(boardID: String, kind: Kind) {
        self.boardID = boardID
        self.kind = kind
    }
}

/// What the UI shows for a destination.
public struct DestinationSnapshot: Sendable, Equatable {
    public struct File: Sendable, Equatable {
        public var url: URL
        public var bytes: Int64
    }

    public var status: DestinationStatus
    /// Records written, sent, or queued for upload.
    public var recordsAccepted = 0
    /// Records waiting to be sent (MQTT, gRPC) or uploaded (NS Analytics).
    public var queueDepth = 0
    /// Records thrown away because a queue was full.
    public var droppedRecords = 0
    public var files: [File] = []
    public var lastError: String?
    /// The last successful send or upload.
    public var lastSuccessAt: Date?

    public init(status: DestinationStatus) {
        self.status = status
    }
}
