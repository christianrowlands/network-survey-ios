import SwiftUI

extension Theme {
    /// Spacing steps and named layout values, in points.
    nonisolated enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24

        /// Left and right margin of every scrolling screen.
        static let screenGutter: CGFloat = 16
        /// Gap between stacked panels.
        static let panelGap: CGFloat = 12
        static let panelPaddingHorizontal: CGFloat = 16
        static let panelPaddingVertical: CGFloat = 14
        static let rowMinHeight: CGFloat = 56
        static let touchTarget: CGFloat = 44
        /// Widest a content column grows on large screens.
        static let contentMaxWidth: CGFloat = 600
    }

    /// Corner radii.
    nonisolated enum Radius {
        static let chip: CGFloat = 8
        static let tile: CGFloat = 12
        static let panel: CGFloat = 14
        static let hero: CGFloat = 16
        static let sheet: CGFloat = 20
    }
}
