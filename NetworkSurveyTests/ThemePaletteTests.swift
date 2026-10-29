import SwiftUI
import Testing
import UIKit
@testable import NetworkSurvey

@Suite("Theme palette")
struct ThemePaletteTests {
    private func rgb(_ color: Color, style: UIUserInterfaceStyle, palette: Palette) -> UInt32 {
        let traits = UITraitCollection { traits in
            traits.userInterfaceStyle = style
            traits[PaletteTrait.self] = palette
        }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return UInt32((red * 255).rounded()) << 16 | UInt32((green * 255).rounded()) << 8 | UInt32((blue * 255).rounded())
    }

    @Test func standardPaletteFollowsTheAppearance() {
        #expect(rgb(Theme.Colors.ground, style: .light, palette: .standard) == 0xF2F4F7)
        #expect(rgb(Theme.Colors.ground, style: .dark, palette: .standard) == 0x0E1116)
    }

    @Test func midnightUsesItsOwnValues() {
        #expect(rgb(Theme.Colors.ground, style: .dark, palette: .midnight) == 0x060B1A)
        #expect(rgb(Theme.Colors.panel, style: .dark, palette: .midnight) == 0x222F52)
        #expect(rgb(Theme.Colors.heroRed, style: .dark, palette: .midnight) == 0x8C1C26)
    }

    @Test func midnightFallsBackToDark() {
        // Record type colors have no Midnight value; they keep their dark one.
        #expect(rgb(Theme.Colors.wifi, style: .dark, palette: .midnight) == 0x4FD0E4)
        #expect(rgb(Theme.Colors.wifi, style: .light, palette: .midnight) == 0x4FD0E4)
    }
}
