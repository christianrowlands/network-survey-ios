import SwiftUI

/// Tokens and list styling for the Map, Lists, details, Settings and Files.
extension Theme.Colors {
    /// Wi-Fi clients: a lighter tint of the Wi-Fi color.
    nonisolated static let wifiClient = Color(light: 0x7FD3DF, dark: 0xA6E9F2)
    /// Glyphs and text drawn on `wifiClient`, which is light in both modes.
    nonisolated static let onWifiClient = Color(hex: 0x0E1116)
    /// Drop shadow under map markers.
    nonisolated static let shadow = Color(light: 0x1B1F26, dark: 0x000000).opacity(0.3)
}

extension View {
    /// The app's ground color behind a List or Form instead of the system
    /// grouped color, so every Settings page matches the Settings root.
    func themedList() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.Colors.ground.ignoresSafeArea())
    }

    /// Panel-colored rows; apply to each Section of a themed List or Form.
    func panelRows() -> some View {
        listRowBackground(Theme.Colors.panel)
    }
}
