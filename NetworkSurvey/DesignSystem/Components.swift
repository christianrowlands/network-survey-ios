import SwiftUI

/// A rounded panel on the screen ground.
struct Panel<Content: View>: View {
    var padding: EdgeInsets = EdgeInsets(
        top: Theme.Spacing.panelPaddingVertical, leading: Theme.Spacing.panelPaddingHorizontal,
        bottom: Theme.Spacing.panelPaddingVertical, trailing: Theme.Spacing.panelPaddingHorizontal
    )
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(padding)
        .background(Theme.Colors.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
    }
}

/// Small uppercase heading above a group of panels.
struct Overline: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(Theme.Fonts.overline)
            .tracking(0.5)
            .foregroundStyle(Theme.Colors.ink2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A short colored label such as a security type or "Hidden".
struct TagPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(Theme.Fonts.tag)
            .foregroundStyle(color)
            .padding(.horizontal, Theme.Spacing.s - 2)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// A colored dot that marks a record type or band.
struct Dot: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The full-width primary action ("Start survey").
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.sectionTitle)
            .frame(maxWidth: .infinity, minHeight: Theme.Spacing.touchTarget + 4)
            .foregroundStyle(Theme.Colors.onAccent)
            .background(Theme.Colors.accent.opacity(isEnabled ? 1 : 0.4), in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

extension View {
    /// Screen background and gutters for a scrolling screen.
    func screenBackground() -> some View {
        background(Theme.Colors.ground.ignoresSafeArea())
    }
}
