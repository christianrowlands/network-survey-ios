import SwiftUI

extension Theme {
    /// The type scale. System text styles so Dynamic Type works, with tabular
    /// figures wherever numbers change live (counters, timers, dBm).
    nonisolated enum Fonts {
        static let screenTitle = Font.title2.weight(.semibold)
        static let sectionTitle = Font.headline
        static let rowTitle = Font.body
        static let body = Font.subheadline
        static let caption = Font.caption
        static let label = Font.caption.weight(.medium)

        /// The elapsed-time readout while recording.
        static let timer = Font.system(.largeTitle, design: .default).weight(.regular).monospacedDigit()
        /// Small uppercase kicker above a section ("RECORDING"). Callers uppercase the text.
        static let overline = Font.caption.weight(.medium)
        /// A live number in a row or chip.
        static let counter = Font.subheadline.monospacedDigit()
        /// The label inside a tag pill ("WPA2", "Hidden").
        static let tag = Font.caption2.weight(.semibold)
        /// Identifiers read character by character: MAC, BSSID, mission ID, file names.
        static let mono = Font.system(.footnote, design: .monospaced).weight(.medium)
    }
}
