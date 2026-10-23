import SwiftUI

/// How well something is going, as a word and a color (never color alone).
enum StatusLevel: Equatable {
    /// Working: records arrive.
    case good
    /// On its way: connecting, queued, starting.
    case pending
    /// Held back: paused, waiting for something.
    case held
    /// Not working: needs the user.
    case failing

    var color: Color {
        switch self {
        case .good: Theme.Colors.green
        case .pending: Theme.Colors.accentInk
        case .held: Theme.Colors.amberText
        case .failing: Theme.Colors.red
        }
    }
}

/// A heading above a panel, with an optional count or note on the right.
struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Overline(text: title)
            Spacer(minLength: Theme.Spacing.s)
            if let trailing {
                Text(trailing)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.ink2)
            }
        }
        .padding(.top, Theme.Spacing.s)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A status word in its level's color.
struct StatusLabel: View {
    let text: String
    let level: StatusLevel

    var body: some View {
        Text(text)
            .font(Theme.Fonts.label)
            .foregroundStyle(level.color)
            .multilineTextAlignment(.trailing)
    }
}

/// A notice that needs the user: what is wrong, why it matters, and the fix.
struct NoticePanel<Actions: View>: View {
    enum Tone { case info, warning, danger }

    let symbol: String
    let title: String
    let message: String
    var tone: Tone = .warning
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(ink)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(title)
                    .font(Theme.Fonts.sectionTitle)
                    .foregroundStyle(Theme.Colors.ink)
                Text(message)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Spacing.l) {
                    actions
                }
                .buttonStyle(.borderless)
                .font(Theme.Fonts.body.weight(.semibold))
                .padding(.top, Theme.Spacing.xs)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var ink: Color {
        switch tone {
        case .info: Theme.Colors.accentInk
        case .warning: Theme.Colors.amberText
        case .danger: Theme.Colors.red
        }
    }

    private var background: Color {
        switch tone {
        case .info: Theme.Colors.accentSoft
        case .warning: Theme.Colors.amberSoft
        case .danger: Theme.Colors.redSoft
        }
    }
}

/// A toggle tile: icon, name and description. On tiles are tinted and carry a
/// check mark, so on and off never differ by color alone.
struct ToggleTile: View {
    let title: String
    let detail: String
    let symbol: String
    let color: Color
    let isOn: Bool
    var isLocked = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack {
                    Image(systemName: symbol)
                        .font(.title3)
                        .foregroundStyle(isOn ? color : Theme.Colors.ink3)
                        // Symbols differ in height; a fixed frame keeps the titles level.
                        .frame(height: 28, alignment: .leading)
                    Spacer(minLength: 0)
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isOn ? Theme.Colors.accent : Theme.Colors.ink3)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(Theme.Fonts.rowTitle.weight(.medium))
                    .foregroundStyle(Theme.Colors.ink)
                Text(detail)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                isOn ? Theme.Colors.accentSoft : Theme.Colors.panel,
                in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                    .strokeBorder(isOn ? Theme.Colors.accent : Theme.Colors.rule, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.tile))
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .opacity(isLocked && !isOn ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint(detail)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// The pinned bar at the bottom of a screen that holds its one main action.
struct ActionBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            content
        }
        .padding(.horizontal, Theme.Spacing.screenGutter)
        .padding(.top, Theme.Spacing.m)
        .padding(.bottom, Theme.Spacing.s)
        .frame(maxWidth: Theme.Spacing.contentMaxWidth)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

/// The full-width destructive action ("Stop survey").
struct StopButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.sectionTitle)
            .frame(maxWidth: .infinity, minHeight: Theme.Spacing.touchTarget + 4)
            .foregroundStyle(Theme.Colors.onAccent)
            .background(Theme.Colors.red.opacity(isEnabled ? 1 : 0.5), in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// A row with a leading symbol, a title, detail lines and trailing content.
struct InfoRow<Trailing: View>: View {
    let symbol: String
    var symbolColor: Color = Theme.Colors.ink2
    let title: String
    var detail: [String] = []
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: symbol)
                .foregroundStyle(symbolColor)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(title)
                    .font(Theme.Fonts.rowTitle)
                    .foregroundStyle(Theme.Colors.ink)
                ForEach(detail, id: \.self) { line in
                    Text(line)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Spacing.s)
            trailing
        }
        .frame(minHeight: Theme.Spacing.rowMinHeight)
    }
}
