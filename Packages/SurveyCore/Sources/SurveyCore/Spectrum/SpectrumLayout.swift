import BoardProtocol
import Foundation

/// Where each access point is drawn on a spectrum chart, which ones get a
/// name label, what a tap hits and how busy each channel is.
extension WifiSpectrum {
    /// The bottom of the chart, where every curve starts and ends.
    public static let floorDBm = -100.0
    /// The highest the y axis goes.
    public static let ceilingDBm = -20.0
    /// Peaks are drawn no higher than this, leaving room for their labels.
    public static let peakLimitDBm = -30.0
    /// How far back the chart looks from the latest beacon, in seconds; the
    /// same window as the signal chart on the detail screens.
    public static let recentWindow: TimeInterval = 120

    /// One access point on a chart: a curve from `low` to `high` (channel
    /// numbers) rising to `peak` dBm over `center`.
    public struct Placement: Sendable, Equatable, Identifiable {
        public var bssid: String
        public var ssid: String?
        public var hidden: Bool
        public var rssi: Int
        public var band: NSBBand
        public var primary: Int
        public var center: Int
        public var width: NSBChannelWidth
        public var low: Double
        public var high: Double
        public var peak: Double
        /// A palette slot that follows the network name (or the BSSID of a
        /// hidden network), so one network keeps its color.
        public var colorSlot: Int

        public var id: String { bssid }

        /// Places an access point by its primary channel and width; an empty
        /// name counts as hidden.
        public init(bssid: String, ssid: String?, rssi: Int, band: NSBBand, primary: Int, width: NSBChannelWidth, colorSlot: Int) {
            let name = ssid?.isEmpty == false ? ssid : nil
            let center = WifiSpectrum.centerChannel(primary: primary, band: band, width: width)
            let half = WifiSpectrum.halfSpan(width)
            self.bssid = bssid
            self.ssid = name
            hidden = name == nil
            self.rssi = rssi
            self.band = band
            self.primary = primary
            self.center = center
            self.width = width
            low = Double(center) - half
            high = Double(center) + half
            peak = min(max(Double(rssi), WifiSpectrum.floorDBm + 5), WifiSpectrum.peakLimitDBm)
            self.colorSlot = colorSlot
        }

        /// The curve's height at `x`, or nil outside it.
        public func level(at x: Double) -> Double? {
            guard x > low, x < high else { return nil }
            return WifiSpectrum.floorDBm + (peak - WifiSpectrum.floorDBm) * WifiSpectrum.shape((x - low) / (high - low))
        }

        /// Points along the curve, edge to edge, for drawing.
        public func outline(samples: Int = 25) -> [CurvePoint] {
            let count = max(samples, 3)
            return (0..<count).map { index in
                let t = Double(index) / Double(count - 1)
                let x = low + (high - low) * t
                return CurvePoint(index: index, x: x, dBm: WifiSpectrum.floorDBm + (peak - WifiSpectrum.floorDBm) * WifiSpectrum.shape(t))
            }
        }
    }

    public struct CurvePoint: Sendable, Equatable {
        public var index: Int
        public var x: Double
        public var dBm: Double
    }

    /// A channel and how many access points overlap it.
    public struct ChannelUse: Sendable, Equatable {
        public var channel: Int
        public var count: Int

        public init(channel: Int, count: Int) {
            self.channel = channel
            self.count = count
        }
    }

    /// A rounded hump: 0 at both edges, 1 across the middle, steep sides,
    /// like a channel's spectral mask.
    static func shape(_ t: Double) -> Double {
        let edge = pow(abs(2 * min(max(t, 0), 1) - 1), 3)
        return pow(max(1 - edge, 0), 1.0 / 3)
    }

    /// The access points drawn in `section`, left to right, then by name.
    public static func placements(_ aps: [AccessPointRow], in section: Section, slots: Int = 8) -> [Placement] {
        aps.compactMap { ap -> Placement? in
            let band = NSBBand(rawValue: ap.band) ?? .unspecified
            guard section.contains(primary: ap.channel, band: band) else { return nil }
            let name = ap.ssid?.isEmpty == false ? ap.ssid : nil
            return Placement(
                bssid: ap.bssid, ssid: name, rssi: ap.rssiLast, band: band, primary: ap.channel,
                width: NSBChannelWidth(rawValue: ap.channelWidth) ?? .unknown,
                colorSlot: colorSlot(for: name ?? ap.bssid, slots: slots)
            )
        }
        .sorted { ($0.center, $0.ssid ?? "\u{10FFFF}", $0.bssid) < ($1.center, $1.ssid ?? "\u{10FFFF}", $1.bssid) }
    }

    /// The top of the y axis for `placements`: 10 dB over the strongest
    /// peak in whole 10 dB steps, from -60 to `ceilingDBm`, so weak networks
    /// still fill the chart and a label fits over every peak.
    public static func top(for placements: [Placement]) -> Double {
        let strongest = placements.map(\.peak).max() ?? floorDBm
        return min(max(((strongest + 10) / 10).rounded(.up) * 10, -60), ceilingDBm)
    }

    /// The access points heard within `window` seconds of the latest one.
    public static func recent(_ aps: [AccessPointRow], window: TimeInterval = recentWindow) -> [AccessPointRow] {
        guard let latest = aps.map(\.lastSeen).max() else { return [] }
        return aps.filter { $0.lastSeen >= latest.addingTimeInterval(-window) }
    }

    /// How many of `aps` each chart would draw, by section ID.
    public static func counts(_ aps: [AccessPointRow]) -> [Section.ID: Int] {
        var counts: [Section.ID: Int] = [:]
        for ap in aps {
            if let section = section(primary: ap.channel, band: NSBBand(rawValue: ap.band) ?? .unspecified) {
                counts[section.id, default: 0] += 1
            }
        }
        return counts
    }

    /// Access points overlapping each 20 MHz channel of `section` (sharing
    /// more than an edge with it).
    public static func occupancy(_ placements: [Placement], in section: Section) -> [ChannelUse] {
        section.primaries.map { channel in
            let low = Double(channel) - 2, high = Double(channel) + 2
            return ChannelUse(channel: channel, count: placements.filter { $0.low < high && $0.high > low }.count)
        }
    }

    /// The busiest channels some access point uses as its primary, busiest
    /// first, ties by channel number.
    public static func busiest(_ placements: [Placement], in section: Section, limit: Int = 3) -> [ChannelUse] {
        let primaries = Set(placements.map(\.primary))
        return Array(occupancy(placements, in: section)
            .filter { primaries.contains($0.channel) && $0.count > 0 }
            .sorted { ($1.count, $0.channel) < ($0.count, $1.channel) }
            .prefix(limit))
    }

    /// The access points that get a name label: strongest first, skipping
    /// any too close to a stronger labeled one to read, at most `limit`.
    public static func labeled(_ placements: [Placement], in section: Section, limit: Int = 8) -> Set<String> {
        let minDistance = (section.domain.upperBound - section.domain.lowerBound) * 0.2
        var kept: [Placement] = []
        for placement in placements.sorted(by: { ($1.peak, $0.bssid) < ($0.peak, $1.bssid) }) where kept.count < limit {
            let clear = kept.allSatisfy { abs(Double($0.center - placement.center)) >= minDistance || abs($0.peak - placement.peak) >= 8 }
            if clear { kept.append(placement) }
        }
        return Set(kept.map(\.bssid))
    }

    /// The access point under a tap at channel `x` and `dBm`: the innermost
    /// curve the tap is inside, else the curve just below the tap (within
    /// `reach` dB, for taps on a label above a peak).
    public static func hit(x: Double, dBm: Double, in placements: [Placement], reach: Double = 10) -> Placement? {
        let levels = placements.compactMap { placement in placement.level(at: x).map { (placement, $0) } }
        if let inside = levels.filter({ $0.1 >= dBm }).min(by: { $0.1 < $1.1 }) { return inside.0 }
        return levels.filter { dBm - $0.1 <= reach }.max { $0.1 < $1.1 }?.0
    }

    /// A stable palette slot for a name (FNV-1a, since `hashValue` changes
    /// with every launch).
    public static func colorSlot(for key: String, slots: Int) -> Int {
        guard slots > 0 else { return 0 }
        var hash: UInt32 = 2_166_136_261
        for byte in key.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Int(hash % UInt32(slots))
    }
}
