import Foundation

/// Log-distance path loss with per-transmitter shadowing and per-frame fading.
enum SimulatedRadio {
    enum Link {
        case wifi24, wifi5, ble

        /// RSSI at 1 m and path loss exponent.
        var reference: (rssiAt1m: Double, exponent: Double) {
            switch self {
            case .wifi24: (-36, 2.8)
            case .wifi5: (-42, 3.1)
            case .ble: (-58, 2.3)
            }
        }
    }

    /// Weakest signal a board decodes.
    static let sensitivity = -94.0
    static let noiseFloor: Int32 = -96

    static func distance(_ a: SimulatedWorld.Point, _ b: SimulatedWorld.Point) -> Double {
        max(1, ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot())
    }

    /// Mean RSSI before fading.
    static func meanRSSI(link: Link, distance: Double, shadowing: Double, txOffset: Double = 0) -> Double {
        let ref = link.reference
        return ref.rssiAt1m - 10 * ref.exponent * log10(distance) + shadowing + txOffset
    }

    /// Draws `count` frame RSSIs around `mean` and returns (max, last), or nil
    /// when none of them was strong enough to decode.
    static func sample(mean: Double, count: Int, rng: inout SeededGenerator) -> (max: Int32, last: Int32, decoded: Int)? {
        var best: Int32?
        var last: Int32 = 0
        var decoded = 0
        for _ in 0..<max(count, 1) {
            let value = mean + rng.noise(sigma: 3)
            guard value >= sensitivity else { continue }
            let rssi = Int32(min(-20, value).rounded())
            best = max(best ?? rssi, rssi)
            last = rssi
            decoded += 1
        }
        guard let best else { return nil }
        return (best, last, decoded)
    }
}
