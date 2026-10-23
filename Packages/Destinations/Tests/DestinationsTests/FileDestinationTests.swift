import BoardProtocol
import Foundation
import NSMessaging
import Testing
@testable import Destinations

@Suite("File destinations")
struct FileDestinationTests {
    func files(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    /// The goldens were written by Apache Commons CSV 1.14.1 with the Android
    /// app's CSV logger code, from the same record JSON.
    @Test("NS Wi-Fi and Bluetooth CSV match the Android app byte for byte")
    func androidGoldens() async throws {
        let directory = Samples.tempDirectory()
        let destination = NSCSVDestination()
        try await destination.start(Samples.session(directory))
        var records: [SurveyRecord] = []
        for index in 1...6 {
            let ns = try WifiBeaconRecord(jsonData: Fixtures.data("csv/wifi-\(index).json"))
            records.append(SurveyRecord(boardID: "NS-1A2B", kind: .ap(ns, NSBApObservation())))
        }
        for index in 1...3 {
            let ns = try BluetoothRecord(jsonData: Fixtures.data("csv/bluetooth-\(index).json"))
            records.append(SurveyRecord(boardID: "NS-1A2B", kind: .ble(ns, NSBBleObservation())))
        }
        await destination.accept(Array(records[0..<4]))
        await destination.accept(Array(records[4...]))
        let snapshot = await destination.snapshot()
        #expect(snapshot.status == .running)
        #expect(snapshot.recordsAccepted == 9)
        await destination.stop()

        #expect(try files(in: directory) == ["craxiom-bluetooth-20261014-180300.csv", "craxiom-wifi-20261014-180300.csv"])
        for (file, golden) in [("craxiom-wifi-20261014-180300.csv", "csv/wifi.golden.csv"),
                               ("craxiom-bluetooth-20261014-180300.csv", "csv/bluetooth.golden.csv")] {
            let actual = try Data(contentsOf: directory.appendingPathComponent(file))
            Fixtures.saveActual(actual, as: file)
            #expect(actual == (try Fixtures.data(golden)), "\(file)")
        }
        let final = await destination.snapshot()
        #expect(final.status == .off)
        #expect(final.files.map(\.bytes).allSatisfy { $0 > 0 })
    }

    @Test("Client and probe CSV (format 0.1.0)")
    func clientAndProbe() async throws {
        let directory = Samples.tempDirectory()
        let destination = NSCSVDestination()
        try await destination.start(Samples.session(directory))
        await destination.accept([Samples.clientRecord(1), Samples.probeRecord(1), Samples.probeRecord(2, board: "NS-3C4D")])
        await destination.stop()
        #expect(try files(in: directory) == ["craxiom-wifi-client-20261014-180300.csv", "craxiom-wifi-probe-20261014-180300.csv"])
        for (name, golden) in [("craxiom-wifi-client-20261014-180300.csv", "csv/client.golden.csv"),
                               ("craxiom-wifi-probe-20261014-180300.csv", "csv/probe.golden.csv")] {
            let actual = try Data(contentsOf: directory.appendingPathComponent(name))
            Fixtures.saveActual(actual, as: name)
            #expect(actual == (try Fixtures.data(golden)), "\(name)")
        }
    }

    @Test("A second session in the same second gets a new file name, and no records means no file")
    func uniqueNames() async throws {
        let directory = Samples.tempDirectory()
        for _ in 0..<2 {
            let destination = NSCSVDestination()
            try await destination.start(Samples.session(directory))
            await destination.accept([Samples.apRecord()])
            await destination.stop()
        }
        let idle = NSCSVDestination()
        try await idle.start(Samples.session(directory))
        await idle.accept([Samples.statusRecord()])
        await idle.stop()
        #expect(try files(in: directory) == ["craxiom-wifi-20261014-180300-1.csv", "craxiom-wifi-20261014-180300.csv"])
    }

    @Test("Commons CSV minimal quoting rules")
    func quoting() {
        #expect(CSVFile.commonsNeedsQuotes("", first: true))
        #expect(!CSVFile.commonsNeedsQuotes("", first: false))
        #expect(CSVFile.commonsNeedsQuotes(" a", first: false))
        #expect(CSVFile.commonsNeedsQuotes("#a", first: false))
        #expect(CSVFile.commonsNeedsQuotes("\"a", first: false))
        #expect(!CSVFile.commonsNeedsQuotes("$a", first: false))
        #expect(!CSVFile.commonsNeedsQuotes("-52.0", first: false))
        #expect(CSVFile.commonsNeedsQuotes("a,b", first: false))
        #expect(CSVFile.commonsNeedsQuotes("a\r", first: false))
        #expect(CSVFile.commonsNeedsQuotes("a ", first: false))
        #expect(!CSVFile.commonsNeedsQuotes("é", first: false))
    }

    @Test("WiGLE CSV")
    func wigle() async throws {
        let directory = Samples.tempDirectory()
        let destination = WiGLEDestination(boardModel: "ESP32-C5")
        try await destination.start(Samples.session(directory))
        var open = Samples.ap
        open.security = .open
        open.akmSuites = []
        open.pairwiseCiphers = []
        open.groupCipher = 0
        open.capabilityInfo = 0x0001
        open.wps = false
        open.ssid = Data("Cafe, \"Guest\"".utf8)
        let openRecord = SurveyRecord(boardID: "NS-1A2B", kind: .ap(WifiBeaconRecord(ap: open, context: Samples.context(2)), open))
        let noLocation = SurveyRecord(
            boardID: "NS-1A2B", kind: .ap(WifiBeaconRecord(ap: open, context: Samples.context(3, location: false)), open)
        )
        await destination.accept([Samples.apRecord(), openRecord, noLocation, Samples.bleRecord(), Samples.probeRecord()])
        #expect(await destination.snapshot().recordsAccepted == 3)
        await destination.stop()
        let name = "craxiom-wigle-20261014-180300.csv"
        #expect(try files(in: directory) == [name])
        let actual = try Data(contentsOf: directory.appendingPathComponent(name))
        Fixtures.saveActual(actual, as: name)
        #expect(actual == (try Fixtures.data("csv/wigle.golden.csv")))
    }

    @Test("WiGLE AuthMode strings")
    func authMode() {
        func ap(_ security: NSBSecurityType, akm: [UInt32], pairwise: [UInt32], group: UInt32, capability: UInt32 = 0x11,
                wps: Bool = false) -> NSBApObservation {
            .with {
                $0.security = security
                $0.akmSuites = akm
                $0.pairwiseCiphers = pairwise
                $0.groupCipher = group
                $0.capabilityInfo = capability
                $0.wps = wps
            }
        }
        #expect(WiGLEAuthMode.string(ap(.open, akm: [], pairwise: [], group: 0, capability: 0x01)) == "[ESS]")
        #expect(WiGLEAuthMode.string(ap(.wep, akm: [], pairwise: [], group: 0)) == "[WEP][ESS]")
        #expect(WiGLEAuthMode.string(ap(.wpa2, akm: [0x000FAC02], pairwise: [0x000FAC04], group: 0x000FAC04))
            == "[WPA2-PSK-CCMP][RSN-PSK-CCMP][ESS]")
        #expect(WiGLEAuthMode.string(ap(.wpa2Wpa3, akm: [0x000FAC02, 0x000FAC08], pairwise: [0x000FAC04], group: 0x000FAC04))
            == "[WPA2-PSK-CCMP][RSN-PSK+SAE-CCMP][ESS]")
        #expect(WiGLEAuthMode.string(ap(.wpa3, akm: [0x000FAC08], pairwise: [0x000FAC04], group: 0x000FAC04))
            == "[RSN-SAE-CCMP][ESS]")
        #expect(WiGLEAuthMode.string(ap(.owe, akm: [0x000FAC12], pairwise: [0x000FAC04], group: 0x000FAC04))
            == "[RSN-OWE-CCMP][ESS]")
        #expect(WiGLEAuthMode.string(ap(.wpa2, akm: [0x000FAC01], pairwise: [0x000FAC04], group: 0x000FAC04))
            == "[WPA2-EAP/SHA1-CCMP][RSN-EAP/SHA1-CCMP][ESS]")
        #expect(WiGLEAuthMode.string(ap(.wpaWpa2, akm: [0x0050F202, 0x000FAC02], pairwise: [0x0050F202, 0x000FAC04],
                                        group: 0x0050F202, capability: 0x11, wps: true))
            == "[WPA-PSK-TKIP][WPA2-PSK-CCMP][RSN-PSK-CCMP][ESS][WPS]")
    }
}
