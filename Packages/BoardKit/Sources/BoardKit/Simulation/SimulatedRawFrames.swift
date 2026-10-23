import BoardProtocol
import Foundation

/// Raw frames for a survey with Configure.raw_frames: one synthetic beacon per
/// AP heard in a dwell, within the board's raw frame rate limit. The frames
/// are well-formed 802.11 beacons (no FCS) built from the AP records.
extension SimulatedBoardEngine {
    /// Raw frames per second when Configure.raw_max_frames_per_sec is 0.
    static let defaultRawFramesPerSecond: UInt32 = 20

    mutating func rawBeacons(for records: [NSBRecord]) -> [NSBRawFrame] {
        let limit = configuration.rawMaxFramesPerSec > 0 ? configuration.rawMaxFramesPerSec : Self.defaultRawFramesPerSecond
        var frames: [NSBRawFrame] = []
        for record in records {
            guard case .ap(let ap) = record.kind, rawFramesThisSecond < limit else { continue }
            rawFramesThisSecond += 1
            let data = Self.beacon(ap, sequence: UInt16(truncatingIfNeeded: rawFramesThisSecond), timeUs: ap.boardTimeMs * 1000)
            frames.append(.with {
                $0.boardTimeUs = ap.boardTimeMs * 1000
                $0.timeSynced = timeSynced
                $0.channel = ap.channel
                $0.frequencyMhz = ap.frequencyMhz
                $0.band = ap.band
                $0.rssi = ap.rssiLast
                $0.noiseFloorDbm = ap.noiseFloorDbm
                $0.phy = .legacy
                // 1 Mbps on 2.4 GHz, 6 Mbps on 5 GHz.
                $0.rate500Kbps = ap.band == .ghz5 ? 12 : 2
                $0.origLen = UInt32(data.count)
                $0.data = data
            })
        }
        return frames
    }

    /// Beacon: header, timestamp, interval, capabilities, then SSID, Supported
    /// Rates and DS Parameter Set elements.
    static func beacon(_ ap: NSBApObservation, sequence: UInt16, timeUs: UInt64) -> Data {
        var frame = Data([0x80, 0x00, 0x00, 0x00])
        frame += Data(repeating: 0xFF, count: 6) + ap.bssid + ap.bssid
        frame += littleEndian(sequence << 4, bytes: 2)
        frame += littleEndian(timeUs, bytes: 8)
        frame += littleEndian(UInt64(ap.beaconIntervalTu), bytes: 2)
        frame += littleEndian(UInt64(ap.capabilityInfo), bytes: 2)
        let ssid = ap.ssid.prefix(32)
        frame += Data([0x00, UInt8(ssid.count)]) + ssid
        let rates: [UInt8] = ap.band == .ghz5
            ? [0x8C, 0x12, 0x98, 0x24, 0xB0, 0x48, 0x60, 0x6C]
            : [0x82, 0x84, 0x8B, 0x96, 0x0C, 0x12, 0x18, 0x24]
        frame += Data([0x01, UInt8(rates.count)] + rates)
        frame += Data([0x03, 0x01, UInt8(truncatingIfNeeded: ap.channel)])
        return frame
    }

    private static func littleEndian(_ value: some FixedWidthInteger, bytes: Int) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: UInt64(value) >> (8 * UInt64($0))) })
    }
}
