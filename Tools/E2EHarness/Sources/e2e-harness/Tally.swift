import Foundation
import Synchronization

/// What arrived on one channel (an MQTT topic, a gRPC method, an NS Analytics
/// record type): enough to compare counts, mission IDs, record numbers and
/// locations with what the app stored.
struct ChannelTally: Codable, Sendable {
    var count = 0
    var missionIds: Set<String> = []
    var serials: Set<String> = []
    var deviceNames: Set<String> = []
    var recordNumbers: [Int] = []
    /// [latitude, longitude] of records with a location.
    var locations: [[Double]] = []
    /// BSSIDs (beacons) or source addresses (others) seen.
    var addresses: Set<String> = []

    mutating func add(_ record: RecordFields) {
        count += 1
        missionIds.insert(record.missionId)
        serials.insert(record.serial)
        deviceNames.insert(record.deviceName)
        recordNumbers.append(record.recordNumber)
        if record.latitude != 0 || record.longitude != 0 { locations.append([record.latitude, record.longitude]) }
        if let address = record.address { addresses.insert(address) }
    }
}

/// The fields every NS Messaging record shares, from JSON or protobuf.
struct RecordFields {
    var missionId = ""
    var serial = ""
    var deviceName = ""
    var recordNumber = 0
    var latitude = 0.0
    var longitude = 0.0
    var address: String?

    /// From an NS Messaging JSON record (`{"version":..,"messageType":..,"data":{..}}`).
    init?(json: Any) {
        guard let object = json as? [String: Any], let data = object["data"] as? [String: Any] else { return nil }
        missionId = data["missionId"] as? String ?? ""
        serial = data["deviceSerialNumber"] as? String ?? ""
        deviceName = data["deviceName"] as? String ?? ""
        recordNumber = (data["recordNumber"] as? NSNumber)?.intValue ?? 0
        latitude = (data["latitude"] as? NSNumber)?.doubleValue ?? 0
        longitude = (data["longitude"] as? NSNumber)?.doubleValue ?? 0
        address = (data["bssid"] as? String) ?? (data["sourceAddress"] as? String)
    }

    init() {}
}

/// Every count the harness keeps, shared by the servers.
final class Tally: Sendable {
    struct Snapshot: Codable, Sendable {
        var mqtt: [String: ChannelTally] = [:]
        var grpc: [String: ChannelTally] = [:]
        /// NS Analytics records by upload type; `nsAnalyticsSkipped` counts the ones answered as skipped.
        var nsAnalytics: [String: ChannelTally] = [:]
        var nsAnalyticsSkipped: [String: Int] = [:]
        var nsAnalyticsBatches = 0
        var nsAnalyticsBatchIDs: Set<String> = []
        var registrations = 0
        var handshakes = 0
        var mqttUnparsed = 0
    }

    private let state = Mutex(Snapshot())

    var snapshot: Snapshot { state.withLock { $0 } }

    func reset() {
        state.withLock { $0 = Snapshot() }
    }

    func update(_ body: (inout Snapshot) -> Void) {
        state.withLock { body(&$0) }
    }
}
