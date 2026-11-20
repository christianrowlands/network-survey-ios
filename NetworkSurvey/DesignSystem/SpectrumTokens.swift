import SwiftUI

extension Theme.Colors {
    /// Network colors on the Wi-Fi spectrum chart, in this fixed order. The
    /// dark steps are the same hues lifted for dark panels. Validated as a
    /// categorical set for color vision deficiency against the panel in light,
    /// dark and Midnight; the light set is below 3:1 for three hues, so the
    /// chart names its curves and lists every network under it.
    nonisolated static let spectrum = [
        Color(light: 0x2A78D6, dark: 0x3987E5),
        Color(light: 0xEB6834, dark: 0xD95926),
        Color(light: 0x1BAF7A, dark: 0x199E70),
        Color(light: 0xEDA100, dark: 0xC98500),
        Color(light: 0xE87BA4, dark: 0xD55181),
        Color(light: 0x008300, dark: 0x0CA30C),
        Color(light: 0x6250D6, dark: 0x9085E9),
        Color(light: 0xE34948, dark: 0xE66767),
    ]

    /// The spectrum color for a palette slot.
    nonisolated static func spectrum(_ slot: Int) -> Color {
        spectrum[((slot % spectrum.count) + spectrum.count) % spectrum.count]
    }
}
