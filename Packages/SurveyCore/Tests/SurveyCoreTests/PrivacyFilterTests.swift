import BoardProtocol
import Foundation
import Testing
@testable import SurveyCore

@Suite("Privacy filter")
struct PrivacyFilterTests {
    let home = GeoPoint(latitude: 38.9000, longitude: -77.0400)

    @Test("Empty by default and allows everything")
    func emptyByDefault() {
        let settings = SettingsStore.inMemory()
        let filter = PrivacyFilter(settings: settings)
        #expect(filter.isEmpty)
        #expect(filter.allows(Fixtures.ap("02:00:5E:00:00:01"), at: home))
    }

    @Test("Zones drop records inside the circle only")
    func zones() {
        let filter = PrivacyFilter(zones: [PrivacyZone(center: home, radiusMeters: 100)])
        let inside = GeoPoint(latitude: 38.9005, longitude: -77.0400)   // about 56 m north
        let outside = GeoPoint(latitude: 38.9010, longitude: -77.0400)  // about 111 m north
        #expect(!filter.allows(Fixtures.ap("02:00:5E:00:00:01"), at: inside))
        #expect(filter.allows(Fixtures.ap("02:00:5E:00:00:01"), at: outside))
        #expect(filter.allows(Fixtures.ap("02:00:5E:00:00:01"), at: nil))
        #expect(filter.isInsideZone(home))
        #expect(abs(home.distance(to: inside) - 55.6) < 1)
    }

    @Test("Zone check widens by the fix's accuracy")
    func zoneAccuracy() {
        let filter = PrivacyFilter(zones: [PrivacyZone(center: home, radiusMeters: 100)])
        let edge = GeoPoint(latitude: 38.9015, longitude: -77.0400)  // about 167 m north
        func fix(_ accuracy: Double?) -> LocationSample {
            LocationSample(latitude: edge.latitude, longitude: edge.longitude, horizontalAccuracy: accuracy, timestamp: .now)
        }
        #expect(filter.allows(Fixtures.ap("02:00:5E:00:00:01"), fix: fix(10)))
        #expect(filter.allows(Fixtures.ap("02:00:5E:00:00:01"), fix: fix(nil)))
        #expect(!filter.allows(Fixtures.ap("02:00:5E:00:00:01"), fix: fix(80)))
        #expect(filter.isInsideZone(fix: fix(80)))
    }

    @Test("SSID matches exactly and case-sensitively")
    func ssid() {
        let filter = PrivacyFilter(ignoreList: [IgnoreEntry(kind: .ssid, value: "HomeNet")])
        #expect(!filter.allows(Fixtures.ap("02:00:5E:00:00:01", ssid: "HomeNet"), at: nil))
        #expect(filter.allows(Fixtures.ap("02:00:5E:00:00:01", ssid: "homenet"), at: nil))
        #expect(filter.allows(Fixtures.ap("02:00:5E:00:00:01", ssid: "HomeNet-5G"), at: nil))
        // A phone probing for the ignored network is dropped too.
        #expect(!filter.allows(Fixtures.probe("0A:11:22:33:44:55", ssid: "HomeNet"), at: nil))
        #expect(filter.allows(Fixtures.probe("0A:11:22:33:44:55", ssid: ""), at: nil))
    }

    @Test("BSSID matches APs and their associated clients")
    func bssid() {
        let filter = PrivacyFilter(ignoreList: [IgnoreEntry(kind: .bssid, value: "02-00-5e-00-00-01")])
        #expect(!filter.allows(Fixtures.ap("02:00:5E:00:00:01"), at: nil))
        #expect(filter.allows(Fixtures.ap("02:00:5E:00:00:02"), at: nil))
        #expect(!filter.allows(Fixtures.client("0A:00:00:00:00:09", associated: "02:00:5E:00:00:01"), at: nil))
        #expect(filter.allows(Fixtures.client("0A:00:00:00:00:09", associated: "02:00:5E:00:00:02"), at: nil))
        // A BSSID entry is not a client MAC entry.
        #expect(filter.allows(Fixtures.client("02:00:5E:00:00:01"), at: nil))
    }

    @Test("MAC and MAC prefix match any address")
    func macs() {
        let filter = PrivacyFilter(ignoreList: [
            IgnoreEntry(kind: .mac, value: "0a:11:22:33:44:55"),
            IgnoreEntry(kind: .macPrefix, value: "02:00:5E:10"),
        ])
        #expect(!filter.allows(Fixtures.client("0A:11:22:33:44:55"), at: nil))
        #expect(!filter.allows(Fixtures.probe("0A:11:22:33:44:55", ssid: "Cafe-Guest"), at: nil))
        #expect(!filter.allows(Fixtures.ble("02:00:5E:10:AA:BB"), at: nil))
        #expect(!filter.allows(Fixtures.ap("02:00:5E:10:00:01"), at: nil))
        #expect(filter.allows(Fixtures.ap("02:00:5E:11:00:01"), at: nil))
        #expect(filter.allows(Fixtures.ble("0A:11:22:33:44:56"), at: nil))
    }

    @Test("Invalid entries are ignored")
    func invalidEntries() {
        let filter = PrivacyFilter(
            zones: [PrivacyZone(center: home, radiusMeters: 0)],
            ignoreList: [IgnoreEntry(kind: .mac, value: "not a mac"), IgnoreEntry(kind: .ssid, value: "")]
        )
        #expect(filter.isEmpty)
    }

    @Test("Raw frames: addresses and the SSID element")
    func rawFrames() {
        let filter = PrivacyFilter(ignoreList: [
            IgnoreEntry(kind: .ssid, value: "HomeNet"), IgnoreEntry(kind: .macPrefix, value: "0A:11"),
        ])
        #expect(!filter.allowsRawFrame(beacon(bssid: [0x02, 0, 0x5E, 0, 0, 1], ssid: "HomeNet"), at: nil))
        #expect(filter.allowsRawFrame(beacon(bssid: [0x02, 0, 0x5E, 0, 0, 1], ssid: "Cafe-Guest"), at: nil))
        #expect(!filter.allowsRawFrame(beacon(bssid: [0x0A, 0x11, 0, 0, 0, 1], ssid: "Cafe-Guest"), at: nil))
        let zoned = PrivacyFilter(zones: [PrivacyZone(center: home, radiusMeters: 50)])
        #expect(!zoned.allowsRawFrame(beacon(bssid: [0x02, 0, 0x5E, 0, 0, 1], ssid: "x"), at: home))
    }

    @Test("Settings round trip the lists")
    func settingsLists() {
        let settings = SettingsStore.inMemory()
        settings[Settings.privacyZones] = [PrivacyZone(name: "Home", center: home, radiusMeters: 150)]
        settings[Settings.ignoreList] = [IgnoreEntry(kind: .ssid, value: "HomeNet")]
        let filter = PrivacyFilter(settings: settings)
        #expect(filter.zones.count == 1)
        #expect(!filter.allows(Fixtures.ap("02:00:5E:00:00:01", ssid: "HomeNet"), at: nil))
    }

    /// A minimal beacon: header, fixed fields, SSID element.
    private func beacon(bssid: [UInt8], ssid: String) -> Data {
        var bytes: [UInt8] = [0x80, 0x00, 0x00, 0x00]
        bytes += [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] + bssid + bssid + [0x00, 0x00]
        bytes += [UInt8](repeating: 0, count: 8) + [0x64, 0x00, 0x11, 0x04]
        bytes += [0x00, UInt8(ssid.utf8.count)] + Array(ssid.utf8)
        return Data(bytes)
    }
}
