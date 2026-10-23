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
}
