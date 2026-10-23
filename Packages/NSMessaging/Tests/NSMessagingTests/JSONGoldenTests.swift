import Foundation
import Testing
@testable import NSMessaging

/// The goldens were printed by the Java protobuf runtime with the printer the
/// Android app uses for MQTT (`preservingProtoFieldNames` and
/// `omittingInsignificantWhitespace`), from the matching `.input.json`.
@Suite("JSON matches the Android app byte for byte")
struct JSONGoldenTests {
    static let names = [
        "beacon-spec-example", "beacon-edge", "probe", "bluetooth", "device-status", "device-status-minimal",
    ]

    @Test(arguments: names)
    func goldens(name: String) throws {
        let input = try Data(contentsOf: try Fixtures.url("json/\(name).input.json"))
        let golden = try Fixtures.text("json/\(name).golden.json").trimmingCharacters(in: .newlines)
        let messageType = try JSONSerialization.jsonObject(with: input) as! [String: Any]
        let encoded: String
        switch messageType["messageType"] as! String {
        case "WifiBeaconRecord": encoded = try WifiBeaconRecord(jsonData: input).jsonString()
        case "WifiProbeRequestRecord": encoded = try WifiProbeRequestRecord(jsonData: input).jsonString()
        case "BluetoothRecord": encoded = try BluetoothRecord(jsonData: input).jsonString()
        case "DeviceStatus": encoded = try DeviceStatus(jsonData: input).jsonString()
        default: Issue.record("unexpected type"); return
        }
        Fixtures.saveActual(encoded, as: "\(name).json")
        #expect(encoded == golden)
    }

    @Test("Decoding and encoding again is lossless")
    func roundTrip() throws {
        let golden = try Data(contentsOf: try Fixtures.url("json/beacon-spec-example.golden.json"))
        let record = try WifiBeaconRecord(jsonData: golden)
        #expect(record.data.cipherSuites == [.tkip, .ccmp])
        #expect(record.data.signalStrength == -73.1)
        #expect(record.data.passpoint == false)
        let again = try WifiBeaconRecord(jsonData: record.jsonData())
        #expect(again == record)
        // Codable through JSONEncoder carries the same content.
        let viaFoundation = try JSONDecoder().decode(WifiBeaconRecord.self, from: JSONEncoder().encode(record))
        #expect(viaFoundation == record)
    }

    @Test("Defaults are left out and unknown enum names decode as UNKNOWN")
    func defaultsAndUnknownNames() throws {
        var data = WifiBeaconRecordData()
        data.bssid = "02:00:5e:00:53:01"
        data.encryptionType = .unknown
        data.channel = 0
        #expect(WifiBeaconRecord(data: data).jsonString()
            == #"{"version":"2.6.0","messageType":"WifiBeaconRecord","data":{"bssid":"02:00:5e:00:53:01","channel":0}}"#)
        let json = #"{"version":"9.0.0","messageType":"WifiBeaconRecord","data":{"encryptionType":"WPA4","extra":1}}"#
        let decoded = try WifiBeaconRecord(jsonData: Data(json.utf8))
        #expect(decoded.data.encryptionType == .unknown)
        #expect(decoded.version == "9.0.0")
    }

    @Test("Fields are listed in field-number order")
    func fieldOrder() {
        func check<T: NSRecordData>(_: T.Type) {
            let numbers = T.fields.map(\.number)
            #expect(numbers == numbers.sorted(), "\(T.self)")
            #expect(Set(T.fields.map(\.name)).count == numbers.count)
        }
        check(WifiBeaconRecordData.self)
        check(WifiProbeRequestRecordData.self)
        check(WifiStationRecordData.self)
        check(BluetoothRecordData.self)
        check(DeviceStatusData.self)
    }

    @Test("Device name stamping leaves empty names alone")
    func stamping() {
        let record = WifiBeaconRecord(data: WifiBeaconRecordData())
        #expect(record.stamped(deviceName: nil) == record)
        #expect(record.stamped(deviceName: "").data.deviceName == "")
        #expect(record.stamped(deviceName: "Field kit 2").data.deviceName == "Field kit 2")
    }
}
