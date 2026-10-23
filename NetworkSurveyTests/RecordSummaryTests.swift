import BoardProtocol
import Foundation
import Testing
@testable import NetworkSurvey

@Suite("Record summary")
struct RecordSummaryTests {
    @Test("AP rows show SSID, BSSID, band and security")
    func accessPoint() throws {
        var ap = NSBApObservation()
        ap.bssid = Data([0x00, 0x00, 0x5E, 0x00, 0x53, 0x01])
        ap.ssid = Data("ExampleNet".utf8)
        ap.channel = 36
        ap.band = .ghz5
        ap.rssiLast = -61
        ap.beaconCount = 2
        ap.security = .wpa2Wpa3
        let row = try #require(RecordSummary(record: .with { $0.ap = ap }, id: 1))
        #expect(row.kind == .ap)
        #expect(row.title == "ExampleNet")
        #expect(row.identifier == "00:00:5E:00:53:01")
        #expect(row.detail == "Ch 36 · 5 GHz · 2 beacons")
        #expect(row.tags == ["WPA2/WPA3"])
        #expect(row.rssi == -61)
    }

    @Test("Hidden networks, wildcard probes and randomized MACs are labeled")
    func labels() throws {
        var ap = NSBApObservation()
        ap.ssidHidden = true
        ap.security = .open
        let apRow = try #require(RecordSummary(record: .with { $0.ap = ap }, id: 1))
        #expect(apRow.title == "Hidden network")
        #expect(apRow.tags == ["Open", "Hidden"])

        var probe = NSBProbeObservation()
        probe.clientMac = Data([0x02, 0x00, 0x5E, 0x10, 0x20, 0x30])
        probe.locallyAdministered = true
        let probeRow = try #require(RecordSummary(record: .with { $0.probe = probe }, id: 2))
        #expect(probeRow.title == "Wildcard probe")
        #expect(probeRow.tags == ["Random MAC"])
    }

    @Test("Empty records are skipped")
    func empty() {
        #expect(RecordSummary(record: NSBRecord(), id: 0) == nil)
    }
}
