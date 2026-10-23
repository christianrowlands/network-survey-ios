import SwiftUI
import UIKit

/// Design tokens shared with the Network Survey Android app: the only place
/// in the app where color values are written down. Views use these names,
/// never literal colors, so light and dark resolve automatically.
nonisolated enum Theme {}

extension Theme {
    nonisolated enum Colors {
        // Neutral ground, panels, ink and rules.
        static let ground = Color(light: 0xF2F4F7, dark: 0x0E1116)
        static let panel = Color(light: 0xFFFFFF, dark: 0x21262E)
        static let panelHigh = Color(light: 0xECEFF3, dark: 0x292F38)
        static let nav = Color(light: 0xFFFFFF, dark: 0x181C22)
        static let ink = Color(light: 0x1B1F26, dark: 0xE8EBF0)
        static let ink2 = Color(light: 0x5B6372, dark: 0xA3ABB6)
        static let ink3 = Color(light: 0x8A93A0, dark: 0x8992A0)
        static let rule = Color(light: 0xE3E6EB, dark: 0x343A44)

        // Interface accent: Navy. (The icon's Sky is a separate brand color.)
        static let accent = Color(light: 0x1E3A6E, dark: 0xA9C1F5)
        static let accentInk = Color(light: 0x1E3A6E, dark: 0xCFDCFA)
        static let accentSoft = Color(light: 0xE3EAF6, dark: 0x1C2B4A)
        static let onAccent = Color(light: 0xFFFFFF, dark: 0x0E1116)

        // Status: green working, amber paused or degraded, red failing.
        static let green = Color(light: 0x1E8E3E, dark: 0x5DC777)
        static let amber = Color(light: 0xB26A00, dark: 0xF0B860)
        static let amberText = Color(light: 0x8A5300, dark: 0xF0B860)
        static let amberSoft = Color(light: 0xFFF3E0, dark: 0x3A2B12)
        static let red = Color(light: 0xC62828, dark: 0xFF7A70)
        static let redSoft = Color(light: 0xFDE8E7, dark: 0x3A1B1A)

        // Record types. Wi-Fi clients and probes use tints of the Wi-Fi color.
        static let wifi = Color(light: 0x0E9BB0, dark: 0x4FD0E4)
        static let bluetooth = Color(light: 0x2F6BFF, dark: 0x7FA4FF)
        static let gnss = Color(light: 0x1E8E3E, dark: 0x5DC777)

        // Wi-Fi bands, always drawn with a halo.
        static let band24 = Color(hex: 0xF2C94C)
        static let band5 = Color(hex: 0x56CCF2)
        static let band6 = Color(hex: 0xBB6BD9)

        // Signal strength for dBm text, strongest first.
        static let signalText = [
            Color(light: 0x276B2B, dark: 0x5DC777),
            Color(light: 0x7F6400, dark: 0xFBC02D),
            Color(light: 0xA84B06, dark: 0xF57C00),
            Color(light: 0xC62828, dark: 0xFF7A70),
            Color(light: 0xA50E0E, dark: 0xFF5252),
        ]

        // Network tag text.
        static let tagSecurity = Color(light: 0x156B4A, dark: 0x77D8B0)
        static let tagOpen = Color(light: 0xA53D24, dark: 0xE88A6C)
        static let tagHidden = Color(light: 0x4F6672, dark: 0x9AADB7)
        static let tagRandomized = Color(light: 0x7B2F8E, dark: 0xCE93D8)

        /// dBm text color on the five-step ramp (-55, -67, -75, -85).
        static func signal(_ rssi: Int32) -> Color {
            switch rssi {
            case (-55)...: signalText[0]
            case (-67)...: signalText[1]
            case (-75)...: signalText[2]
            case (-85)...: signalText[3]
            default: signalText[4]
            }
        }
    }
}

nonisolated extension Color {
    /// A color that follows the light or dark appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    init(hex: UInt32) {
        self.init(uiColor: UIColor(rgb: hex))
    }
}

nonisolated extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
