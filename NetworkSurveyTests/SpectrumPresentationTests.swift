import BoardProtocol
import SurveyCore
import Testing
@testable import NetworkSurvey

@Suite("Wi-Fi spectrum text")
struct SpectrumPresentationTests {
    let band24 = WifiSpectrum.sections[0]
    let band5Low = WifiSpectrum.sections[1]

    private func place(_ ssid: String?, channel: Int, rssi: Int, width: NSBChannelWidth = .mhz20, band: NSBBand = .ghz24,
                       bssid: String = "02:00:5E:00:00:01") -> WifiSpectrum.Placement {
        WifiSpectrum.Placement(bssid: bssid, ssid: ssid, rssi: rssi, band: band, primary: channel, width: width, colorSlot: 0)
    }

    @Test func bandsShow6GHzOnlyWithAccessPointsThere() {
        #expect(SpectrumPresentation.bands(counts: [:]) == [.ghz24, .ghz5])
        #expect(SpectrumPresentation.bands(counts: ["6-mid": 0]) == [.ghz24, .ghz5])
        #expect(SpectrumPresentation.bands(counts: ["6-mid": 2]) == [.ghz24, .ghz5, .ghz6])
    }

    @Test func titlesNameTheChannelRange() {
        #expect(SpectrumPresentation.title(band24) == "2.4 GHz")
        #expect(SpectrumPresentation.title(band5Low) == "5 GHz, channels 36 to 64")
        #expect(SpectrumPresentation.empty(band24) == "No access points in this band")
        #expect(SpectrumPresentation.empty(band5Low) == "No access points on channels 36 to 64")
    }

    @Test func hiddenNetworksAndChannels() {
        let hidden = place("", channel: 36, rssi: -60, width: .mhz80, band: .ghz5)
        #expect(hidden.hidden)
        #expect(SpectrumPresentation.chartLabel(hidden) == "Hidden")
        #expect(SpectrumPresentation.name(hidden) == "Hidden network")
        #expect(SpectrumPresentation.channel(hidden) == "Channel 36 · 80 MHz")
        #expect(SpectrumPresentation.chartLabel(place("ExampleNet", channel: 6, rssi: -50)) == "ExampleNet")
    }

    @Test func summaryNamesBusiestChannelsAndStrongest() {
        let placements = [
            place("ExampleNet", channel: 6, rssi: -48, bssid: "02:00:5E:00:00:01"),
            place("CafeNet", channel: 6, rssi: -71, bssid: "02:00:5E:00:00:02"),
            place(nil, channel: 11, rssi: -80, bssid: "02:00:5E:00:00:03"),
        ]
        #expect(SpectrumPresentation.summary(placements, in: band24)
            == "3 access points. Busiest channels: 6 with 2, 11 with 1. Strongest: ExampleNet on channel 6 at -48 dBm.")
        #expect(SpectrumPresentation.summary([placements[2]], in: band24).hasPrefix("1 access point. "))
        #expect(SpectrumPresentation.summary([], in: band5Low) == "No access points on channels 36 to 64.")
    }

    @Test func windowSaysWhatRecentMeans() {
        #expect(SpectrumPresentation.window(isPast: false) == "Heard in the last 2 minutes")
        #expect(SpectrumPresentation.window(isPast: true) == "Heard in the last 2 minutes of this survey")
    }
}
