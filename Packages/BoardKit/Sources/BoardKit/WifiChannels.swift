import BoardProtocol

/// Wi-Fi channel numbers and frequencies used by boards (20 MHz primaries).
public enum WifiChannels {
    public static let band24: [UInt32] = Array(1...13)

    /// 5 GHz primaries an ESP32-C5 can receive on (UNII-1 to UNII-3, DFS included,
    /// since the board only listens).
    public static let band5: [UInt32] =
        [36, 40, 44, 48, 52, 56, 60, 64]
        + [100, 104, 108, 112, 116, 120, 124, 128, 132, 136, 140, 144]
        + [149, 153, 157, 161, 165]

    public static func band(of channel: UInt32) -> NSBBand {
        switch channel {
        case 1...14: .ghz24
        case 32...177: .ghz5
        default: .unspecified
        }
    }

    public static func frequencyMHz(of channel: UInt32) -> UInt32 {
        switch channel {
        case 14: 2484
        case 1...13: 2407 + 5 * channel
        case 32...177: 5000 + 5 * channel
        default: 0
        }
    }

    /// The channels a board supports for the bands it reports.
    public static func supported(bands: [NSBBand]) -> [UInt32] {
        (bands.contains(.ghz24) ? band24 : []) + (bands.contains(.ghz5) ? band5 : [])
    }
}
