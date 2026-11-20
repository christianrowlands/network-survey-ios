import Foundation
import Testing
@testable import NSMessaging

/// The expected strings are the ones network-survey-messaging's
/// `JsonConversionTest` checks the Java protobuf printer against (the printer
/// the Android app uses for MQTT), so these match Android byte for byte.
@Suite("Watchlist messages match the Android app")
struct WatchlistJSONTests {
    static let matchJSON = #"{"version":"2.4.0","messageType":"WatchlistMatch","data":{"deviceSerialNumber":"1234","deviceName":"Craxiom Pixel","deviceTime":"1996-12-19T16:39:57-08:00","latitude":51.470334,"longitude":-0.486594,"altitude":13.3,"missionId":"Survey1 20200724-154325","recordNumber":1,"accuracy":40,"locationAge":5000,"speed":1.5,"entryUuid":"a1b2c3d4","label":"Rogue AP","matchType":"EXACT","matchedField":"BSSID","ssid":"My Wi-Fi Network","bssid":"68:7f:74:b0:14:98","signalStrength":-58.5}}"#

    static let entryUpdateJSON = #"{"version":"2.4.0","messageType":"WatchlistEntryUpdate","data":{"deviceSerialNumber":"1234","deviceName":"Craxiom Pixel","deviceTime":"1996-12-19T16:39:57-08:00","missionId":"Survey1 20200724-154325","messageSequence":"42","changeType":"SNAPSHOT","entries":[{"entryUuid":"a1b2c3d4","label":"Rogue AP","ssid":"My Wi-Fi Network","bssid":"68:7f:74:b0:14:98","matchType":"EXACT","enabled":true,"cooldownSeconds":900,"createdAt":"1996-12-19T16:39:57-08:00","updatedAt":"1996-12-19T16:39:57-08:00"}]}}"#

    @Test("WatchlistMatch")
    func match() throws {
        var data = WatchlistMatchData()
        data.deviceSerialNumber = "1234"
        data.deviceName = "Craxiom Pixel"
        data.deviceTime = "1996-12-19T16:39:57-08:00"
        data.latitude = 51.470334
        data.longitude = -0.486594
        data.altitude = 13.3
        data.missionId = "Survey1 20200724-154325"
        data.recordNumber = 1
        data.accuracy = 40
        data.locationAge = 5000
        data.speed = 1.5
        data.entryUuid = "a1b2c3d4"
        data.label = "Rogue AP"
        data.matchType = .exact
        data.matchedField = .bssid
        data.ssid = "My Wi-Fi Network"
        data.bssid = "68:7f:74:b0:14:98"
        data.signalStrength = -58.5
        let record = WatchlistMatch(data: data, version: "2.4.0")
        #expect(record.jsonString() == Self.matchJSON)
        #expect(try WatchlistMatch(jsonData: Data(Self.matchJSON.utf8)) == record)
    }

    @Test("WatchlistEntryUpdate")
    func entryUpdate() throws {
        var entry = WatchlistEntryMessage()
        entry.entryUuid = "a1b2c3d4"
        entry.label = "Rogue AP"
        entry.ssid = "My Wi-Fi Network"
        entry.bssid = "68:7f:74:b0:14:98"
        entry.matchType = .exact
        entry.enabled = true
        entry.cooldownSeconds = 900
        entry.createdAt = "1996-12-19T16:39:57-08:00"
        entry.updatedAt = "1996-12-19T16:39:57-08:00"
        var data = WatchlistEntryUpdateData()
        data.deviceSerialNumber = "1234"
        data.deviceName = "Craxiom Pixel"
        data.deviceTime = "1996-12-19T16:39:57-08:00"
        data.missionId = "Survey1 20200724-154325"
        data.messageSequence = 42
        data.changeType = .snapshot
        data.entries = [entry]
        let record = WatchlistEntryUpdate(data: data, version: "2.4.0")
        #expect(record.jsonString() == Self.entryUpdateJSON)
        let decoded = try WatchlistEntryUpdate(jsonData: Data(Self.entryUpdateJSON.utf8))
        #expect(decoded == record)
        #expect(decoded.data.messageSequence == 42)
    }

    @Test("Wrapper fields: enabled false is sent, a missing SSID is left out, an empty list is left out")
    func wrappers() {
        var entry = WatchlistEntryMessage()
        entry.entryUuid = "u"
        entry.bssid = "02:00:5e:00:53:01"
        entry.enabled = false
        entry.ssid = nil
        var data = WatchlistEntryUpdateData()
        data.messageSequence = 1_800_000_000_123
        data.changeType = .snapshot
        data.entries = [entry, entry]
        #expect(WatchlistEntryUpdate(data: data).jsonString()
            == #"{"version":"2.7.0","messageType":"WatchlistEntryUpdate","data":{"messageSequence":"1800000000123","changeType":"SNAPSHOT","entries":[{"entryUuid":"u","bssid":"02:00:5e:00:53:01","enabled":false},{"entryUuid":"u","bssid":"02:00:5e:00:53:01","enabled":false}]}}"#)
        data.entries = []
        #expect(WatchlistEntryUpdate(data: data).jsonString()
            == #"{"version":"2.7.0","messageType":"WatchlistEntryUpdate","data":{"messageSequence":"1800000000123","changeType":"SNAPSHOT"}}"#)
        // An unknown match field decodes as UNKNOWN; a numeric sequence is read too.
        let json = #"{"version":"2.7.0","messageType":"WatchlistEntryUpdate","data":{"messageSequence":7,"changeType":"DELTA"}}"#
        let decoded = try? WatchlistEntryUpdate(jsonData: Data(json.utf8))
        #expect(decoded?.data.messageSequence == 7 && decoded?.data.changeType == .unknown)
    }

    @Test("The device name is stamped on both kinds")
    func stamping() {
        #expect(WatchlistMatch(data: WatchlistMatchData()).stamped(deviceName: "Field kit").data.deviceName == "Field kit")
        #expect(WatchlistEntryUpdate(data: WatchlistEntryUpdateData()).stamped(deviceName: "Field kit").data.deviceName == "Field kit")
    }
}
