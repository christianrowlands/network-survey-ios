import BoardProtocol
import Destinations
import Foundation
import NSMessaging

public enum SessionFiles {
    /// `<root>/Surveys/<yyyyMMdd-HHmmss>/` for a session started at `startedAt`.
    public static func directory(root: URL, startedAt: Date, timeZone: TimeZone = .current) -> URL {
        root.appendingPathComponent("Surveys", isDirectory: true)
            .appendingPathComponent(MissionID.timestamp(startedAt, timeZone: timeZone), isDirectory: true)
    }
}

/// Feeds the Destinations package: converts each batch to NS Messaging records
/// once and hands it to every destination of the session.
public final class DestinationHub: SurveyRecordSink {
    public let destinations: [any Destination]
    public let name = "destinations"

    public init(_ destinations: [any Destination]) {
        self.destinations = destinations
    }

    /// A destination that fails to start reports it in its snapshot; the
    /// others still run, so this never throws.
    public func start(_ session: SessionContext) async throws {
        let info = SessionInfo(
            missionId: session.missionId, startedAt: session.startedAt, directory: session.directory,
            deviceSerialNumber: session.deviceSerialNumber, deviceName: session.deviceName,
            deviceModel: session.app.deviceModel, osVersion: session.app.osVersion,
            appVersion: session.app.appVersion, timeZone: session.timeZone
        )
        for destination in destinations {
            try? await destination.start(info)
        }
    }

    public func accept(_ records: [SurveyOutput]) async {
        guard !records.isEmpty else { return }
        let converted = records.map { $0.surveyRecord() }
        for destination in destinations { await destination.accept(converted) }
    }

    public func acceptRaw(_ frames: [RawFrameOutput]) async {
        let records = frames.map { SurveyRecord(boardID: $0.boardID, kind: .rawFrame($0.frame, timestamp: $0.time)) }
        for destination in destinations where destination.kind == .pcap {
            await destination.accept(records)
        }
    }

    public func stop() async {
        for destination in destinations { await destination.stop() }
    }

    public func snapshots() async -> [String: DestinationSnapshot] {
        var result: [String: DestinationSnapshot] = [:]
        for destination in destinations { result[destination.kind.rawValue] = await destination.snapshot() }
        return result
    }
}

extension LocationSample {
    var fix: LocationFix {
        LocationFix(
            latitude: latitude, longitude: longitude, altitude: altitude, horizontalAccuracy: horizontalAccuracy,
            speed: speed, timestamp: timestamp, source: source == .phone ? .phone : .boardGPS
        )
    }
}

extension SurveyOutput {
    /// The NS Messaging record plus the board observation it came from.
    func surveyRecord(timeZone: TimeZone = .current) -> SurveyRecord {
        let context = RecordContext(
            deviceSerialNumber: self.context.deviceSerialNumber, missionId: self.context.missionId,
            recordNumber: Int32(clamping: self.context.recordNumber), deviceTime: self.context.deviceTime,
            location: self.context.location?.fix, timeZone: timeZone
        )
        let kind: SurveyRecord.Kind
        switch payload {
        case .accessPoint(let ap): kind = .ap(WifiBeaconRecord(ap: ap, context: context), ap)
        case .probe(let probe): kind = .probe(WifiProbeRequestRecord(probe: probe, context: context), probe)
        case .client(let client): kind = .client(WifiStationRecord(client: client, context: context), client)
        case .ble(let ble): kind = .ble(BluetoothRecord(ble: ble, context: context), ble)
        case .deviceStatus(let info):
            kind = .deviceStatus(DeviceStatus(
                context: context, deviceModel: info.deviceModel, appVersion: info.appVersion,
                batteryLevelPercent: info.batteryLevelPercent.map { Int32(clamping: $0) }, gnss: info.boardGPS?.fix
            ))
        }
        return SurveyRecord(boardID: self.context.boardID ?? "", kind: kind)
    }
}
