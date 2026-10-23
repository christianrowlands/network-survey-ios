import Foundation
import NSMessaging
import SwiftProtobuf

typealias ProtoWifiBeaconRecord = Com_Craxiom_Messaging_WifiBeaconRecord
typealias ProtoWifiProbeRequestRecord = Com_Craxiom_Messaging_WifiProbeRequestRecord
typealias ProtoBluetoothRecord = Com_Craxiom_Messaging_BluetoothRecord
typealias ProtoDeviceStatus = Com_Craxiom_Messaging_DeviceStatus
typealias WirelessSurveyService = Com_Craxiom_Messaging_Grpc_WirelessSurvey
typealias DeviceStatusService = Com_Craxiom_Messaging_Grpc_DeviceStatus
typealias ConnectionHandshakeService = Com_Craxiom_Messaging_Grpc_ConnectionHandshake

/// The client-streaming RPCs the gRPC destination keeps open, one per record type.
enum GRPCStream: CaseIterable, Sendable {
    case wifiBeacon, wifiProbeRequest, bluetooth, deviceStatus
}

/// A record converted to its NS Messaging protobuf message.
enum GRPCOutgoing: Sendable {
    case wifiBeacon(ProtoWifiBeaconRecord)
    case wifiProbeRequest(ProtoWifiProbeRequestRecord)
    case bluetooth(ProtoBluetoothRecord)
    case deviceStatus(ProtoDeviceStatus)

    var stream: GRPCStream {
        switch self {
        case .wifiBeacon: .wifiBeacon
        case .wifiProbeRequest: .wifiProbeRequest
        case .bluetooth: .bluetooth
        case .deviceStatus: .deviceStatus
        }
    }

    /// The protobuf message for a record, built from its NS Messaging JSON (the
    /// JSON uses the proto field names, so the protobuf JSON parser maps every
    /// field). Station records have no gRPC method and are not sent.
    init?(_ record: SurveyRecord, deviceName: String) throws {
        switch record.kind {
        case .ap(let ns, _): self = .wifiBeacon(try Self.decode(ns.stamped(deviceName: deviceName).jsonString()))
        case .probe(let ns, _): self = .wifiProbeRequest(try Self.decode(ns.stamped(deviceName: deviceName).jsonString()))
        case .ble(let ns, _): self = .bluetooth(try Self.decode(ns.stamped(deviceName: deviceName).jsonString()))
        case .deviceStatus(let ns): self = .deviceStatus(try Self.decode(ns.stamped(deviceName: deviceName).jsonString()))
        case .client, .rawFrame: return nil
        }
    }

    static func decode<M: SwiftProtobuf.Message>(_ json: String) throws -> M {
        try M(jsonString: json)
    }

    var wifiBeacon: ProtoWifiBeaconRecord? { if case .wifiBeacon(let m) = self { m } else { nil } }
    var wifiProbeRequest: ProtoWifiProbeRequestRecord? { if case .wifiProbeRequest(let m) = self { m } else { nil } }
    var bluetooth: ProtoBluetoothRecord? { if case .bluetooth(let m) = self { m } else { nil } }
    var deviceStatus: ProtoDeviceStatus? { if case .deviceStatus(let m) = self { m } else { nil } }
}
