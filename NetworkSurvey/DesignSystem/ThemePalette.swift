import SwiftUI
import UIKit

/// Which set of dark values `Theme.Colors` resolves to. Midnight is always
/// dark; the light and dark appearances both use the standard palette.
nonisolated enum Palette: Int, Sendable {
    case standard
    case midnight
}

/// Carries the palette through UIKit traits, so every view, sheet and alert in
/// a window scene resolves the same colors and redraws when it changes.
nonisolated struct PaletteTrait: UITraitDefinition {
    static let defaultValue = Palette.standard
    static let affectsColorAppearance = true
    static let name = "Palette"
}

/// Bridges the trait into SwiftUI, which resolves `Theme.Colors` against its
/// environment rather than the hosting view's traits.
private nonisolated struct PaletteKey: UITraitBridgedEnvironmentKey {
    static let defaultValue = Palette.standard

    static func read(from traitCollection: UITraitCollection) -> Palette {
        traitCollection[PaletteTrait.self]
    }

    static func write(to mutableTraits: inout UIMutableTraits, value: Palette) {
        mutableTraits[PaletteTrait.self] = value
    }
}

extension EnvironmentValues {
    nonisolated var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}
