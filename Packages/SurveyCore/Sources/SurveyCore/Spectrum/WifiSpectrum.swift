import BoardProtocol
import Foundation

/// Wi-Fi channel geometry for the spectrum chart: where a channel of a given
/// width sits, in channel numbers, and how the bands split into charts.
///
/// The chart's x axis is in channel numbers, which are 5 MHz apart in every
/// band, so a channel `W` MHz wide spans `W / 10` channel numbers on each side
/// of its center.
public enum WifiSpectrum {
    /// The channel width in MHz; unknown widths count as 20 MHz, and 80+80 as
    /// 80 MHz because the second segment's position is not reported.
    public static func widthMHz(_ width: NSBChannelWidth) -> Int {
        switch width {
        case .mhz40: 40
        case .mhz80, .mhz80P80: 80
        case .mhz160: 160
        case .mhz320: 320
        default: 20
        }
    }

    /// Channel numbers from the center to each edge.
    public static func halfSpan(_ width: NSBChannelWidth) -> Double {
        Double(widthMHz(width)) / 10
    }

    /// The center channel of a channel `width` wide whose primary 20 MHz
    /// channel is `primary`. A primary outside the band's channel blocks keeps
    /// its own number.
    ///
    /// Beacons do not say which side a 2.4 GHz 40 MHz channel extends to, so
    /// primaries 1 to 7 are taken to extend up and 8 to 13 down (the only
    /// direction channels 1 to 4 and 10 to 13 allow).
    public static func centerChannel(primary: Int, band: NSBBand, width: NSBChannelWidth) -> Int {
        let mhz = widthMHz(width)
        guard mhz > 20 else { return primary }
        switch band {
        case .ghz24:
            guard mhz == 40, (1...13).contains(primary) else { return primary }
            return primary <= 7 ? primary + 2 : primary - 2
        case .ghz5:
            return center5(primary: primary, mhz: mhz)
        case .ghz6:
            return center6(primary: primary, mhz: mhz)
        default:
            return primary
        }
    }

    /// The center frequency of a channel `width` wide, in MHz; 0 when the
    /// band is unknown.
    public static func centerFrequencyMHz(primary: Int, band: NSBBand, width: NSBChannelWidth) -> Int {
        frequencyMHz(channel: centerChannel(primary: primary, band: band, width: width), band: band)
    }

    /// The frequency of a channel number in a band, in MHz.
    public static func frequencyMHz(channel: Int, band: NSBBand) -> Int {
        switch band {
        case .ghz24: channel == 14 ? 2484 : 2407 + 5 * channel
        case .ghz5: 5000 + 5 * channel
        case .ghz6: channel == 2 ? 5935 : 5950 + 5 * channel
        default: 0
        }
    }

    // MARK: - Channel blocks

    /// 5 GHz bonding blocks start at 36 (UNII-1 to UNII-2e) and 149 (UNII-3).
    private static func center5(primary: Int, mhz: Int) -> Int {
        let base: Int
        switch primary {
        case 36...144: base = 36
        case 149...177: base = 149
        default: return primary
        }
        let block = blockCenter(primary: primary, base: base, mhz: mhz)
        // No 160 MHz channel covers 132 to 144; such an AP is at most 80 MHz wide.
        if mhz == 160 && primary >= 132 && primary <= 144 { return blockCenter(primary: primary, base: base, mhz: 80) }
        return block
    }

    /// 6 GHz channels 1 to 233; 320 MHz channels overlap, so the ones centered
    /// on 31, 95 and 159 are used, and 191 for the top of the band.
    private static func center6(primary: Int, mhz: Int) -> Int {
        guard (1...233).contains(primary), primary % 4 == 1 else { return primary }
        if mhz >= 320 { return primary >= 193 ? 191 : blockCenter(primary: primary, base: 1, mhz: 320) }
        return blockCenter(primary: primary, base: 1, mhz: mhz)
    }

    /// The center of the `mhz` block holding `primary`, blocks starting at `base`.
    private static func blockCenter(primary: Int, base: Int, mhz: Int) -> Int {
        let channels = mhz / 5
        let block = (primary - base) / channels
        return base + block * channels + channels / 2 - 2
    }
}

extension WifiSpectrum {
    /// One chart: a band, or part of a wide band, with its channel axis.
    public struct Section: Sendable, Hashable, Identifiable {
        public let id: String
        public let band: NSBBand
        /// The channel range, for a picker ("36 to 64"); empty when the band
        /// has one chart.
        public let name: String
        /// Primary 20 MHz channels an AP must use to be drawn here.
        public let channels: ClosedRange<Int>
        /// The x axis, in channel numbers: the channels and `margin` more on
        /// each side, so a 20 MHz channel at either end fits.
        public let domain: ClosedRange<Double>
        /// Primary channel numbers, for grid lines and occupancy counts.
        public let primaries: [Int]
        /// Channel numbers labeled on the x axis.
        public let ticks: [Int]

        public init(id: String, band: NSBBand, name: String, channels: ClosedRange<Int>, step: Int, labelStep: Int, margin: Int = 4) {
            self.id = id
            self.band = band
            self.name = name
            self.channels = channels
            domain = Double(channels.lowerBound - margin)...Double(channels.upperBound + margin)
            primaries = Array(stride(from: channels.lowerBound, through: channels.upperBound, by: step))
            ticks = Array(stride(from: channels.lowerBound, through: channels.upperBound, by: step * labelStep))
        }

        /// Whether an AP on `primary` in `band` is drawn in this chart.
        public func contains(primary: Int, band: NSBBand) -> Bool {
            band == self.band && channels.contains(primary)
        }
    }

    /// The charts, in band order. 5 and 6 GHz are split so a 20 MHz channel
    /// stays wide enough to see and tap on a phone.
    public static let sections: [Section] = [
        Section(id: "2.4", band: .ghz24, name: "", channels: 1...13, step: 1, labelStep: 1, margin: 2),
        Section(id: "5-low", band: .ghz5, name: "36 to 64", channels: 36...64, step: 4, labelStep: 1),
        Section(id: "5-mid", band: .ghz5, name: "100 to 144", channels: 100...144, step: 4, labelStep: 2),
        Section(id: "5-high", band: .ghz5, name: "149 to 177", channels: 149...177, step: 4, labelStep: 1),
        Section(id: "6-low", band: .ghz6, name: "1 to 93", channels: 1...93, step: 4, labelStep: 4),
        Section(id: "6-mid", band: .ghz6, name: "97 to 189", channels: 97...189, step: 4, labelStep: 4),
        Section(id: "6-high", band: .ghz6, name: "193 to 233", channels: 193...233, step: 4, labelStep: 2),
    ]

    /// The charts of one band.
    public static func sections(of band: NSBBand) -> [Section] {
        sections.filter { $0.band == band }
    }

    /// The chart an AP on `primary` is drawn in, if any.
    public static func section(primary: Int, band: NSBBand) -> Section? {
        sections.first { $0.contains(primary: primary, band: band) }
    }
}
