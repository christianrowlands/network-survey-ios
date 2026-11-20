import BoardProtocol
import Foundation
import Testing
@testable import SurveyCore

@Suite("Wi-Fi spectrum")
struct SpectrumTests {
    let t0 = Fixtures.base

    func ap(
        _ bssid: String, ssid: String? = "ExampleNet", channel: Int, band: NSBBand = .ghz24,
        width: NSBChannelWidth = .mhz20, rssi: Int = -60, at offset: TimeInterval = 0
    ) -> AccessPointRow {
        AccessPointRow(
            sessionId: "S1", bssid: bssid, ssid: ssid, ssidHidden: ssid == nil, band: band.rawValue, channel: channel,
            frequencyMhz: WifiSpectrum.frequencyMHz(channel: channel, band: band), security: 4, groupCipher: 0,
            pairwiseCiphers: "", akmSuites: "", channelWidth: width.rawValue, phyFlags: 0, wps: false, passpoint: false,
            randomized: false, firstSeen: t0, lastSeen: t0 + offset, observationCount: 1, frameCount: 1, rssiLast: rssi,
            rssiMax: rssi, lastBoardId: "B1"
        )
    }

    @Test("Center channels of bonded 5 GHz channels follow the channel blocks")
    func centers5() {
        func center(_ primary: Int, _ width: NSBChannelWidth) -> Int {
            WifiSpectrum.centerChannel(primary: primary, band: .ghz5, width: width)
        }
        #expect(center(36, .mhz20) == 36)
        #expect([36, 40].map { center($0, .mhz40) } == [38, 38])
        #expect([44, 48].map { center($0, .mhz40) } == [46, 46])
        #expect(center(140, .mhz40) == 142 && center(144, .mhz40) == 142)
        #expect(center(153, .mhz40) == 151 && center(165, .mhz40) == 167)
        #expect([36, 40, 44, 48].map { center($0, .mhz80) } == [42, 42, 42, 42])
        #expect(center(52, .mhz80) == 58 && center(100, .mhz80) == 106 && center(144, .mhz80) == 138)
        #expect(center(149, .mhz80) == 155 && center(161, .mhz80) == 155 && center(165, .mhz80) == 171)
        #expect(center(64, .mhz160) == 50 && center(100, .mhz160) == 114 && center(177, .mhz160) == 163)
        // No 160 MHz block covers 132 to 144: drawn as the 80 MHz one.
        #expect(center(136, .mhz160) == 138)
        #expect(center(52, .mhz80P80) == 58)
        #expect(center(200, .mhz80) == 200)
    }

    @Test("2.4 and 6 GHz center channels")
    func centers24And6() {
        #expect(WifiSpectrum.centerChannel(primary: 1, band: .ghz24, width: .mhz40) == 3)
        #expect(WifiSpectrum.centerChannel(primary: 6, band: .ghz24, width: .mhz40) == 8)
        #expect(WifiSpectrum.centerChannel(primary: 11, band: .ghz24, width: .mhz40) == 9)
        #expect(WifiSpectrum.centerChannel(primary: 6, band: .ghz24, width: .unknown) == 6)
        func center(_ primary: Int, _ width: NSBChannelWidth) -> Int {
            WifiSpectrum.centerChannel(primary: primary, band: .ghz6, width: width)
        }
        #expect(center(5, .mhz40) == 3 && center(13, .mhz40) == 11)
        #expect(center(37, .mhz80) == 39 && center(97, .mhz160) == 111)
        #expect(center(1, .mhz320) == 31 && center(97, .mhz320) == 95 && center(189, .mhz320) == 159)
        #expect(center(221, .mhz320) == 191)
    }

    @Test("Frequencies and spans")
    func frequenciesAndSpans() {
        #expect(WifiSpectrum.frequencyMHz(channel: 6, band: .ghz24) == 2437)
        #expect(WifiSpectrum.frequencyMHz(channel: 14, band: .ghz24) == 2484)
        #expect(WifiSpectrum.frequencyMHz(channel: 36, band: .ghz5) == 5180)
        #expect(WifiSpectrum.frequencyMHz(channel: 1, band: .ghz6) == 5955)
        #expect(WifiSpectrum.centerFrequencyMHz(primary: 36, band: .ghz5, width: .mhz80) == 5210)
        #expect(WifiSpectrum.centerFrequencyMHz(primary: 36, band: .ghz5, width: .mhz160) == 5250)
        let spans = [NSBChannelWidth.mhz20, .mhz40, .mhz80, .mhz160, .mhz320, .mhz80P80, .unknown].map(WifiSpectrum.halfSpan)
        #expect(spans == [2, 4, 8, 16, 32, 8, 2])
    }

    @Test("Sections split the bands and pick their access points")
    func sections() throws {
        #expect(WifiSpectrum.sections(of: .ghz24).count == 1)
        #expect(WifiSpectrum.sections(of: .ghz5).map(\.name) == ["36 to 64", "100 to 144", "149 to 177"])
        #expect(WifiSpectrum.sections(of: .ghz6).count == 3)
        #expect(WifiSpectrum.sections[0].domain == -1...15)
        let low = try #require(WifiSpectrum.sections.first { $0.id == "5-low" })
        #expect(low.domain == 32...68)
        #expect(low.primaries == [36, 40, 44, 48, 52, 56, 60, 64])
        #expect(WifiSpectrum.sections[0].ticks == Array(1...13))
        #expect(WifiSpectrum.section(primary: 100, band: .ghz5)?.id == "5-mid")
        #expect(WifiSpectrum.section(primary: 6, band: .ghz5) == nil)

        let aps = [
            ap("02:00:5E:00:00:01", ssid: "Zeta", channel: 36, band: .ghz5, width: .mhz80, rssi: -50),
            ap("02:00:5E:00:00:02", ssid: "Alpha", channel: 44, band: .ghz5, width: .mhz40),
            ap("02:00:5E:00:00:03", ssid: nil, channel: 36, band: .ghz5),
            ap("02:00:5E:00:00:04", channel: 149, band: .ghz5),
            ap("02:00:5E:00:00:05", channel: 6),
        ]
        let placed = WifiSpectrum.placements(aps, in: low)
        #expect(placed.map(\.bssid) == ["02:00:5E:00:00:03", "02:00:5E:00:00:01", "02:00:5E:00:00:02"])
        let wide = try #require(placed.first { $0.ssid == "Zeta" })
        #expect(wide.center == 42 && wide.low == 34 && wide.high == 50 && wide.peak == -50)
        #expect(placed[0].hidden && placed[0].ssid == nil)
        #expect(WifiSpectrum.counts(aps) == ["5-low": 3, "5-high": 1, "2.4": 1])
    }

    @Test("Peaks stay inside the chart and curves rise from the floor")
    func curves() throws {
        let section = WifiSpectrum.sections[0]
        let placed = WifiSpectrum.placements([
            ap("02:00:5E:00:00:01", channel: 6, rssi: -12), ap("02:00:5E:00:00:02", channel: 1, rssi: -120),
        ], in: section)
        #expect(placed.map(\.peak) == [-95, -30])
        let outline = placed[1].outline(samples: 25)
        #expect(outline.first?.x == 4 && outline.last?.x == 8)
        #expect(outline.first?.dBm == WifiSpectrum.floorDBm && outline.last?.dBm == WifiSpectrum.floorDBm)
        #expect(outline[12].x == 6 && outline[12].dBm == -30)
        // Symmetric, and rising steeply: a quarter of the way in it is most of the way up.
        #expect(abs(outline[6].dBm - outline[18].dBm) < 1e-9)
        #expect(try #require(placed[1].level(at: 5)) > -40)
        #expect(placed[1].level(at: 8) == nil && placed[1].level(at: 3.9) == nil)
    }

    @Test("The y axis grows with the strongest peak")
    func top() {
        let section = WifiSpectrum.sections[0]
        func top(_ rssi: [Int]) -> Double {
            WifiSpectrum.top(for: WifiSpectrum.placements(rssi.map { ap("02:00:5E:00:00:\($0)", channel: 6, rssi: $0) }, in: section))
        }
        #expect(top([]) == -60)
        #expect(top([-90, -85]) == -60)
        #expect(top([-90, -65]) == -50)
        #expect(top([-60]) == -50)
        #expect(top([-41]) == -30)
        #expect(top([-10]) == -20)
    }

    @Test("Recent keeps the two minutes up to the latest beacon")
    func recent() {
        let aps = [ap("02:00:5E:00:00:01", channel: 1, at: 0), ap("02:00:5E:00:00:02", channel: 6, at: 100),
                   ap("02:00:5E:00:00:03", channel: 11, at: 200)]
        #expect(WifiSpectrum.recent(aps).map(\.bssid) == ["02:00:5E:00:00:02", "02:00:5E:00:00:03"])
        #expect(WifiSpectrum.recent([]).isEmpty)
    }

    @Test("Busiest channels count overlapping access points")
    func busiest() {
        let section = WifiSpectrum.sections[0]
        let placed = WifiSpectrum.placements([
            ap("02:00:5E:00:00:01", channel: 6), ap("02:00:5E:00:00:02", channel: 6), ap("02:00:5E:00:00:03", channel: 1),
            ap("02:00:5E:00:00:04", channel: 11), ap("02:00:5E:00:00:05", channel: 1, width: .mhz40),
        ], in: section)
        let use = WifiSpectrum.occupancy(placed, in: section)
        #expect(use.count == 13)
        #expect(use[0] == .init(channel: 1, count: 2))
        // Channel 4 shares spectrum with all but the AP on 11.
        #expect(use[3] == .init(channel: 4, count: 4))
        // 20 MHz neighbors 4 channels apart only touch at the edge.
        #expect(use[10] == .init(channel: 11, count: 1))
        // Only channels in use as a primary are reported.
        #expect(WifiSpectrum.busiest(placed, in: section) == [
            .init(channel: 6, count: 3), .init(channel: 1, count: 2), .init(channel: 11, count: 1),
        ])
        #expect(WifiSpectrum.busiest(placed, in: section, limit: 1).count == 1)
        #expect(WifiSpectrum.busiest([], in: section).isEmpty)
    }

    @Test("Labels skip curves crowded by a stronger labeled one")
    func labels() {
        let section = WifiSpectrum.sections[0]
        let placed = WifiSpectrum.placements([
            ap("02:00:5E:00:00:01", channel: 6, rssi: -40), ap("02:00:5E:00:00:02", channel: 6, rssi: -45),
            ap("02:00:5E:00:00:03", channel: 7, rssi: -70), ap("02:00:5E:00:00:04", channel: 1, rssi: -42),
            ap("02:00:5E:00:00:05", channel: 11, rssi: -80),
        ], in: section)
        #expect(WifiSpectrum.labeled(placed, in: section) == ["02:00:5E:00:00:01", "02:00:5E:00:00:03", "02:00:5E:00:00:04", "02:00:5E:00:00:05"])
        #expect(WifiSpectrum.labeled(placed, in: section, limit: 2) == ["02:00:5E:00:00:01", "02:00:5E:00:00:04"])
    }

    @Test("A tap picks the innermost curve, or the one just below")
    func hits() {
        let section = WifiSpectrum.sections[1]
        let placed = WifiSpectrum.placements([
            ap("02:00:5E:00:00:01", channel: 36, band: .ghz5, width: .mhz80, rssi: -50),
            ap("02:00:5E:00:00:02", channel: 40, band: .ghz5, rssi: -75),
        ], in: section)
        #expect(WifiSpectrum.hit(x: 40, dBm: -90, in: placed)?.bssid == "02:00:5E:00:00:02")
        #expect(WifiSpectrum.hit(x: 40, dBm: -60, in: placed)?.bssid == "02:00:5E:00:00:01")
        #expect(WifiSpectrum.hit(x: 45, dBm: -90, in: placed)?.bssid == "02:00:5E:00:00:01")
        #expect(WifiSpectrum.hit(x: 42, dBm: -44, in: placed)?.bssid == "02:00:5E:00:00:01")
        #expect(WifiSpectrum.hit(x: 42, dBm: -30, in: placed) == nil)
        #expect(WifiSpectrum.hit(x: 60, dBm: -90, in: placed) == nil)
    }

    @Test("Color slots are stable and follow the network name")
    func colors() {
        #expect(WifiSpectrum.colorSlot(for: "ExampleNet", slots: 8) == WifiSpectrum.colorSlot(for: "ExampleNet", slots: 8))
        #expect((0..<8).contains(WifiSpectrum.colorSlot(for: "ExampleNet", slots: 8)))
        // FNV-1a of "a" is 0xE40C292C.
        #expect(WifiSpectrum.colorSlot(for: "a", slots: 1000) == Int(0xE40C292C % 1000))
        let section = WifiSpectrum.sections[0]
        let placed = WifiSpectrum.placements([ap("02:00:5E:00:00:01", channel: 1), ap("02:00:5E:00:00:02", channel: 11)], in: section)
        #expect(placed[0].colorSlot == placed[1].colorSlot)
    }

    @Test("Recent access points come from the store")
    func query() async throws {
        let store = try SurveyStore.inMemory()
        try await store.insertSession(Fixtures.sessionRow())
        func stored(_ bssid: String, at offset: TimeInterval) -> StoredRecord {
            StoredRecord(boardID: "B1", time: t0 + offset, location: nil, kind: Fixtures.ap(bssid, time: t0 + offset))
        }
        #expect(try await store.read { try StoreQueries.recentAccessPoints($0, sessionID: "S1") }.isEmpty)
        try await store.write(sessionID: "S1", records: [
            stored("02:00:5E:00:00:01", at: 0), stored("02:00:5E:00:00:02", at: 200), stored("02:00:5E:00:00:03", at: 300),
        ], trackPoints: [])
        let recent = try await store.read { try StoreQueries.recentAccessPoints($0, sessionID: "S1") }
        #expect(recent.map(\.bssid) == ["02:00:5E:00:00:02", "02:00:5E:00:00:03"])
    }
}
