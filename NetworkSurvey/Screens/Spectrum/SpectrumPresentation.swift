import BoardProtocol
import SurveyCore

/// Text for the Wi-Fi spectrum screen: titles, row details and the summary
/// VoiceOver reads for each chart.
nonisolated enum SpectrumPresentation {
    /// Bands with a chart: the ones a Scout receives, and 6 GHz only when the
    /// survey has 6 GHz access points.
    static func bands(counts: [WifiSpectrum.Section.ID: Int]) -> [NSBBand] {
        let has6 = WifiSpectrum.sections(of: .ghz6).contains { counts[$0.id, default: 0] > 0 }
        return [.ghz24, .ghz5] + (has6 ? [.ghz6] : [])
    }

    static func bandName(_ band: NSBBand) -> String {
        switch band {
        case .ghz24: "2.4 GHz"
        case .ghz5: "5 GHz"
        case .ghz6: "6 GHz"
        default: "Unknown band"
        }
    }

    /// "2.4 GHz", or "5 GHz, channels 36 to 64" for part of a band.
    static func title(_ section: WifiSpectrum.Section) -> String {
        section.name.isEmpty ? bandName(section.band) : "\(bandName(section.band)), channels \(section.name)"
    }

    /// The name on the chart: short, so curves stay readable.
    static func chartLabel(_ placement: WifiSpectrum.Placement) -> String {
        placement.ssid ?? "Hidden"
    }

    /// The name in the list under the chart, as the Lists show it.
    static func name(_ placement: WifiSpectrum.Placement) -> String {
        placement.ssid ?? "Hidden network"
    }

    /// "Channel 36 · 80 MHz".
    static func channel(_ placement: WifiSpectrum.Placement) -> String {
        "Channel \(placement.primary) · \(WifiSpectrum.widthMHz(placement.width)) MHz"
    }

    /// What the chart shows when it has no curves.
    static func empty(_ section: WifiSpectrum.Section) -> String {
        section.name.isEmpty ? "No access points in this band" : "No access points on channels \(section.name)"
    }

    /// What VoiceOver reads for a chart: how many access points, the busiest
    /// channels and the strongest network.
    static func summary(_ placements: [WifiSpectrum.Placement], in section: WifiSpectrum.Section) -> String {
        guard let strongest = placements.max(by: { ($0.rssi, $1.bssid) < ($1.rssi, $0.bssid) }) else {
            return "\(empty(section))."
        }
        let count = placements.count == 1 ? "1 access point" : "\(placements.count) access points"
        let busiest = WifiSpectrum.busiest(placements, in: section).map { "\($0.channel) with \($0.count)" }
        let busy = busiest.isEmpty ? "" : " Busiest channels: \(busiest.joined(separator: ", "))."
        return "\(count).\(busy) Strongest: \(name(strongest)) on channel \(strongest.primary) at \(strongest.rssi) dBm."
    }

    /// The caption over the chart: what "recent" means for this survey.
    static func window(isPast: Bool) -> String {
        let minutes = Int(WifiSpectrum.recentWindow / 60)
        return isPast ? "Heard in the last \(minutes) minutes of this survey" : "Heard in the last \(minutes) minutes"
    }
}
