import BoardProtocol
import Foundation
import Testing
@testable import NSMessaging

/// Synthetic board observations shared by the converter tests.
enum Samples {
    static let utc = TimeZone(identifier: "UTC")!
    static let time = Date(timeIntervalSince1970: 1_792_000_987.25)

    static func context(_ number: Int32 = 1, location: Bool = true) -> RecordContext {
        RecordContext(
            deviceSerialNumber: "8C2E1F7A-0B5D-4E16-9A3F-2D7C4B6E1A90",
            missionId: "NS 8C2E1F7A-0B5D-4E16-9A3F-2D7C4B6E1A90 20261014-180000",
            recordNumber: number, deviceTime: time,
            location: location ? LocationFix(
                latitude: 38.889484, longitude: -77.035278, altitude: 21.3, horizontalAccuracy: 4.6,
                speed: 1.25, timestamp: time.addingTimeInterval(-0.8)
            ) : nil,
            timeZone: utc
        )
    }

    static func data(_ bytes: [UInt8]) -> Data { Data(bytes) }

    static var ap: NSBApObservation {
        .with {
            $0.boardTimeMs = 1_792_000_987_250
            $0.channel = 36
            $0.frequencyMhz = 5180
            $0.band = .ghz5
            $0.bssid = data([0x02, 0x00, 0x5E, 0x00, 0x53, 0x01])
            $0.ssid = Data("ExampleNet".utf8)
            $0.rssiMax = -48
            $0.rssiLast = -51
            $0.noiseFloorDbm = -95
            $0.beaconCount = 2
            $0.beaconIntervalTu = 100
            $0.capabilityInfo = 0x0011
            $0.security = .wpa2Wpa3
            $0.groupCipher = 0x000FAC04
            $0.pairwiseCiphers = [0x000FAC04]
            $0.akmSuites = [0x000FAC02, 0x000FAC08]
            $0.phyFlags = UInt32(NSBPhyFlag.ht.rawValue | NSBPhyFlag.vht.rawValue | NSBPhyFlag.he.rawValue)
            $0.channelWidth = .mhz80
            $0.wps = true
            $0.supportedRates = data([0x8C, 0x12, 0x98, 0x24, 0xB0, 0x48, 0x60, 0x6C])
        }
    }

    static var probe: NSBProbeObservation {
        .with {
            $0.boardTimeMs = 1_792_000_987_250
            $0.channel = 6
            $0.frequencyMhz = 2437
            $0.band = .ghz24
            $0.clientMac = data([0x06, 0x1A, 0x2B, 0x3C, 0x4D, 0x5E])
            $0.ssid = Data("Cafe-Guest".utf8)
            $0.rssiMax = -62
            $0.rssiLast = -70
            $0.count = 3
            $0.locallyAdministered = true
            $0.destinationAddress = data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
            $0.bssid = data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
            $0.phyFlags = UInt32(NSBPhyFlag.ht.rawValue)
        }
    }

    static var client: NSBClientObservation {
        .with {
            $0.channel = 11
            $0.frequencyMhz = 2462
            $0.band = .ghz24
            $0.clientMac = data([0x0A, 0x11, 0x22, 0x33, 0x44, 0x55])
            $0.associatedBssid = data([0x02, 0x00, 0x5E, 0x00, 0x53, 0x02])
            $0.rssiMax = -55
            $0.rssiLast = -60
            $0.noiseFloorDbm = -92
            $0.frameCount = 14
            $0.sourceFlags = UInt32(NSBClientSource.data.rawValue | NSBClientSource.nullData.rawValue)
            $0.locallyAdministered = true
        }
    }

    static var ble: NSBBleObservation {
        .with {
            $0.channel = 37
            $0.address = data([0xC2, 0x00, 0x5E, 0x00, 0x53, 0x10])
            $0.addressType = .random
            $0.rssiMax = -71
            $0.rssiLast = -75
            $0.count = 9
            $0.advType = .advInd
            // Flags (LE only), 16-bit UUIDs 0x180D and 0xFE9F, local name, manufacturer 0x004C.
            $0.advData = data([
                0x02, 0x01, 0x06,
                0x05, 0x03, 0x0D, 0x18, 0x9F, 0xFE,
                0x08, 0x09, 0x45, 0x78, 0x61, 0x6D, 0x70, 0x6C, 0x65,
                0x07, 0xFF, 0x4C, 0x00, 0x12, 0x02, 0x00, 0x03,
            ])
            $0.localName = Data("Example".utf8)
            $0.companyID = 0x004C
            $0.txPower = 8
        }
    }
}

@Suite("Board records convert to NS Messaging records")
struct ConverterTests {
    func checkGolden(_ json: String, _ name: String) throws {
        Fixtures.saveActual(json, as: "\(name).json")
        let golden = try Fixtures.text("json/\(name).golden.json").trimmingCharacters(in: .newlines)
        #expect(json == golden)
    }

    @Test func beaconGolden() throws {
        try checkGolden(WifiBeaconRecord(ap: Samples.ap, context: Samples.context()).jsonString(), "convert-beacon")
    }

    @Test func probeGolden() throws {
        try checkGolden(WifiProbeRequestRecord(probe: Samples.probe, context: Samples.context(2)).jsonString(), "convert-probe")
    }

    @Test func bluetoothGolden() throws {
        try checkGolden(BluetoothRecord(ble: Samples.ble, context: Samples.context(3)).jsonString(), "convert-bluetooth")
    }

    @Test func stationGolden() throws {
        try checkGolden(WifiStationRecord(client: Samples.client, context: Samples.context(4)).jsonString(), "convert-station")
    }

    @Test func deviceStatusGolden() throws {
        let gnss = LocationFix(latitude: 38.88949, longitude: -77.03528, altitude: 20, horizontalAccuracy: 2.5,
                               timestamp: Samples.time.addingTimeInterval(-1.5), source: .boardGPS)
        let status = DeviceStatus(context: Samples.context(5), deviceModel: "iPhone17,3", appVersion: "1.0.0",
                                  batteryLevelPercent: 77, gnss: gnss)
        try checkGolden(status.jsonString(), "convert-device-status")
    }

    @Test("Without a location the location fields are left out")
    func noLocation() {
        let data = WifiBeaconRecord(ap: Samples.ap, context: Samples.context(location: false)).data
        #expect(data.latitude == 0 && data.longitude == 0 && data.altitude == 0)
        #expect(data.accuracy == 0 && data.locationAge == 0 && data.speed == 0)
        #expect(data.recordNumber == 1)
        #expect(data.deviceTime == "2026-10-14T18:03:07.25Z")
    }

    @Test("Location fields follow the Android rules")
    func locationRules() {
        var context = Samples.context()
        context.location?.speed = 0.05
        context.location?.horizontalAccuracy = 0.3
        let data = WifiBeaconRecord(ap: Samples.ap, context: context).data
        #expect(data.speed == 0) // below 0.1 m/s is left out
        #expect(data.accuracy == 1) // (0, 0.5) rounds to 1
        #expect(data.locationAge == 800)
        #expect(data.altitude == 21.3)
        context.location?.horizontalAccuracy = -1 // CoreLocation's "invalid"
        #expect(WifiBeaconRecord(ap: Samples.ap, context: context).data.accuracy == 0)
        context.location?.horizontalAccuracy = 1e12
        #expect(WifiBeaconRecord(ap: Samples.ap, context: context).data.accuracy == Int32.max)
    }

    @Test("Encryption types: OWE has no NS value, enterprise keeps its bucket and AKMs")
    func encryption() {
        var ap = Samples.ap
        ap.security = .owe
        ap.akmSuites = [0x000FAC12]
        var data = WifiBeaconRecord(ap: ap, context: Samples.context()).data
        #expect(data.encryptionType == .unknown)
        #expect(data.akmSuites == [.unknown])
        #expect(data.cipherSuites == [.ccmp])

        ap.security = .wpa2
        ap.akmSuites = [0x000FAC01, 0x000FAC03, 0x000FAC05]
        data = WifiBeaconRecord(ap: ap, context: Samples.context()).data
        #expect(data.encryptionType == .wpa2)
        #expect(data.akmSuites == [.ieee8021x, .ftIeee8021x, .ieee8021xSha256])

        ap.security = .wpa3
        ap.akmSuites = [0x000FAC0C]
        ap.pairwiseCiphers = [0x000FAC09]
        ap.groupCipher = 0x000FAC09
        data = WifiBeaconRecord(ap: ap, context: Samples.context()).data
        #expect(data.encryptionType == .wpa3)
        #expect(data.akmSuites == [.unknown])
        #expect(data.cipherSuites == [.gcmp256])

        ap.security = .wpaWpa2
        ap.akmSuites = [0x0050F202, 0x000FAC02]
        ap.pairwiseCiphers = [0x0050F202, 0x000FAC04]
        ap.groupCipher = 0x0050F202
        data = WifiBeaconRecord(ap: ap, context: Samples.context()).data
        #expect(data.encryptionType == .wpaWpa2)
        #expect(data.akmSuites == [.psk])
        #expect(data.cipherSuites == [.tkip, .ccmp])

        for (security, expected) in [(NSBSecurityType.open, CipherSuite.open), (.wep, .wep)] {
            ap.security = security
            ap.akmSuites = []
            ap.pairwiseCiphers = []
            ap.groupCipher = 0
            data = WifiBeaconRecord(ap: ap, context: Samples.context()).data
            #expect(data.cipherSuites == [expected])
        }
        #expect(WifiFields.encryptionType(.wpa2Wpa3) == .wpa2Wpa3)
    }

    @Test("Standard and bandwidth come from the PHY flags, band and rates")
    func standardAndBandwidth() {
        let ht = UInt32(NSBPhyFlag.ht.rawValue)
        let vht = UInt32(NSBPhyFlag.vht.rawValue)
        #expect(WifiFields.standard(phyFlags: 8 | 4 | ht, band: .ghz5) == .ieee80211be)
        #expect(WifiFields.standard(phyFlags: 4 | ht, band: .ghz24) == .ieee80211ax)
        #expect(WifiFields.standard(phyFlags: vht | ht, band: .ghz5) == .ieee80211ac)
        #expect(WifiFields.standard(phyFlags: vht | ht, band: .ghz24) == .ieee80211n)
        #expect(WifiFields.standard(phyFlags: ht, band: .ghz5) == .ieee80211n)
        #expect(WifiFields.standard(phyFlags: 0, band: .ghz5) == .ieee80211a)
        #expect(WifiFields.standard(phyFlags: 0, band: .ghz24, rates: Data([0x82, 0x84, 0x8B, 0x96])) == .ieee80211b)
        #expect(WifiFields.standard(phyFlags: 0, band: .ghz24, rates: Data([0x8C, 0x12, 0x98])) == .ieee80211g)
        #expect(WifiFields.standard(phyFlags: 0, band: .ghz24, rates: Data([0x82, 0x84, 0x0C])) == .ieee80211bg)
        #expect(WifiFields.standard(phyFlags: 0, band: .ghz24) == .unknown)
        #expect(WifiFields.bandwidth(.unknown, phyFlags: 0) == .mhz20)
        #expect(WifiFields.bandwidth(.unknown, phyFlags: ht) == .unknown)
        #expect(WifiFields.bandwidth(.mhz80P80, phyFlags: vht) == .mhz80Plus)
        #expect(WifiFields.bandwidth(.mhz320, phyFlags: 8) == .mhz320)
    }

    @Test("Rates, addresses and SSIDs are formatted like the Android app")
    func formatting() {
        #expect(WifiFields.rates(Data([0x82, 0x84, 0x8B, 0x96, 0x24, 0x30, 0x48, 0x6C])) == "1; 2; 5.5; 11; 18; 24; 36; 54")
        #expect(WifiFields.rates(Data([0x0C, 0xFF, 0xFB])) == "6") // membership selectors dropped
        #expect(WifiFields.mac(Data([0x02, 0xAB, 0, 0, 0, 1])) == "02:ab:00:00:00:01")
        #expect(WifiFields.mac(Data([0x02, 0xAB, 0, 0, 0, 1]), uppercase: true) == "02:AB:00:00:00:01")
        #expect(WifiFields.mac(Data([1, 2])) == "")
        #expect(WifiFields.ssid(Data([0, 0, 0])) == "")
        #expect(WifiFields.ssid(Data([0x41, 0xFF, 0x42])) == "A\u{FFFD}B")
        #expect(WifiFields.serviceSetType(capabilityInfo: 0x0002) == .ibss)
        #expect(WifiFields.frameTypes(sourceFlags: 0x7F).count == 7)
    }

    @Test("Hidden APs report an empty SSID")
    func hiddenSSID() {
        var ap = Samples.ap
        ap.ssidHidden = true
        ap.ssid = Data([0, 0, 0, 0])
        #expect(WifiBeaconRecord(ap: ap, context: Samples.context()).data.ssid == "")
    }

    @Test("Advertising data parsing")
    func advertisingData() {
        let ad = AdvertisingData(Data([
            0x02, 0x01, 0x1A, // Flags: BR/EDR supported
            0x05, 0x05, 0x78, 0x56, 0x34, 0x12, // 32-bit UUID
            0x11, 0x07, 0xFB, 0x34, 0x9B, 0x5F, 0x80, 0x00, 0x00, 0x80, 0x00, 0x10, 0x00, 0x00, 0x0F, 0x18, 0x00, 0x00,
            0x03, 0xFF, 0xE0, 0x00, // manufacturer with only the ID
            0x04, 0xFF, 0x06, 0x00, 0x01, // a second manufacturer structure is ignored
            0x09, 0x16, // truncated structure ends parsing
        ]))
        #expect(ad.supportedTechnologies == .dual)
        #expect(ad.serviceUUIDs == ["12345678-0000-1000-8000-00805f9b34fb", "0000180f-0000-1000-8000-00805f9b34fb"])
        #expect(ad.manufacturerData == [0xE0, 0x00])
        #expect(AdvertisingData(Data()).supportedTechnologies == .unknown)

        var ble = Samples.ble
        ble.advData = Data([0x03, 0xFF, 0xE0, 0x00])
        let data = BluetoothRecord(ble: ble, context: Samples.context()).data
        #expect(data.companyId == "e0")
        #expect(data.mfgData == "")
        #expect(data.supportedTechnologies == .unknown)
    }
}
