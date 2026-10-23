import BoardKit
import BoardProtocol
import SwiftUI

/// One chip per board in use: short ID, role, battery, channels, records per
/// second and a drop warning. Tapping a chip sets the board's role.
struct BoardStrip: View {
    @Environment(AppModel.self) private var model
    let onSelect: (BoardID) -> Void

    /// Chips keep one width while a survey runs, so the strip never reflows.
    static let chipWidth: CGFloat = 168

    var body: some View {
        let boards = model.boardsInUse
        if boards.count <= 2 {
            // One or two boards share the width equally.
            Grid(horizontalSpacing: Theme.Spacing.s) {
                GridRow(alignment: .top) {
                    ForEach(boards, id: \.self) { chip($0) }
                    if boards.count == 1 { Color.clear.gridCellUnsizedAxes([.vertical]) }
                }
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Theme.Spacing.s) {
                    ForEach(boards, id: \.self) { chip($0).frame(width: Self.chipWidth) }
                }
            }
            .scrollClipDisabled()
        }
    }

    private func chip(_ board: BoardID) -> some View {
        Button { onSelect(board) } label: {
            BoardChip(board: board)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("survey.boardChip")
    }
}

struct BoardChip: View {
    @Environment(AppModel.self) private var model
    let board: BoardID

    var body: some View {
        let state = model.boardManager.boards[board]
        let connected = state?.connection.isConnected == true && state?.isReady == true
        let drops = (state?.counters.droppedRecords ?? 0) + (state?.counters.missedNotifications ?? 0)
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.xs) {
                Dot(color: connected ? Theme.Colors.green : Theme.Colors.amber)
                Text(model.boardName(board))
                    .font(Theme.Fonts.mono)
                    .foregroundStyle(Theme.Colors.ink)
                Spacer(minLength: 0)
                if model.isDemo(board) {
                    TagPill(text: "Demo", color: Theme.Colors.accentInk)
                }
            }
            Text(roleLine(state))
                .font(Theme.Fonts.caption.monospacedDigit())
                .foregroundStyle(connected ? Theme.Colors.ink2 : Theme.Colors.amberText)
                .lineLimit(1)
            HStack(spacing: Theme.Spacing.m) {
                if let percent = state?.status.flatMap(BoardBattery.percent) {
                    Label("\(percent)%", systemImage: BoardBattery.symbol(percent))
                        .foregroundStyle(percent < 15 ? Theme.Colors.red : Theme.Colors.ink2)
                } else {
                    Text("No battery info")
                        .foregroundStyle(Theme.Colors.ink3)
                }
                Spacer(minLength: 0)
                if drops > 0 {
                    Label(drops.formatted(), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Colors.amberText)
                }
                if connected, state?.assignment != nil, let rate = state?.status?.recordsPerSec {
                    Text("\(rate)/s")
                        .foregroundStyle(Theme.Colors.ink2)
                }
            }
            .font(Theme.Fonts.caption.monospacedDigit())
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .frame(maxWidth: .infinity, minHeight: Theme.Spacing.touchTarget, alignment: .leading)
        .background(Theme.Colors.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .strokeBorder(connected ? Theme.Colors.rule : Theme.Colors.amber, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(state, connected: connected, drops: drops))
        .accessibilityHint("Sets the board's role")
    }

    private func roleLine(_ state: BoardManager.BoardState?) -> String {
        let connection = BoardText.connection(state)
        guard connection == "Connected" else { return connection }
        return BoardText.assignment(state?.assignment, status: state?.status) ?? model.role(of: board).title
    }

    private func accessibilityText(_ state: BoardManager.BoardState?, connected: Bool, drops: Int) -> String {
        var parts = [model.boardName(board)]
        if model.isDemo(board) { parts.append("demo board") }
        parts.append(roleLine(state))
        if let percent = state?.status.flatMap(BoardBattery.percent) { parts.append("battery \(percent) percent") }
        if connected, state?.assignment != nil, let rate = state?.status?.recordsPerSec { parts.append("\(rate) records per second") }
        if drops > 0 { parts.append("\(drops) records lost") }
        return parts.joined(separator: ", ")
    }
}

/// Picks a board's role. While a survey runs the change applies at once.
struct BoardRolePicker: View {
    @Environment(AppModel.self) private var model
    let board: BoardID
    @State private var channel: UInt32 = 6

    var body: some View {
        let bands = model.boardManager.boards[board]?.info?.bands ?? [.ghz24]
        let current = model.role(of: board)
        Section {
            ForEach(BoardRolePreference.choices(bands: bands), id: \.self) { role in
                Button {
                    choose(role.sameKind(as: .fixedChannel(0)) ? .fixedChannel(channel) : role)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text(role.title).foregroundStyle(Theme.Colors.ink)
                            Text(role.sameKind(as: .fixedChannel(0)) ? "Stays on one channel, so nothing on it is missed." : role.explanation)
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.Colors.ink2)
                        }
                        Spacer()
                        if role.sameKind(as: current) {
                            Image(systemName: "checkmark").foregroundStyle(Theme.Colors.accent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(role.sameKind(as: current) ? .isSelected : [])
                .accessibilityIdentifier("role.\(role.title)")
            }
            if case .fixedChannel = current {
                Picker("Channel", selection: $channel) {
                    ForEach(WifiChannels.supported(bands: bands), id: \.self) { channel in
                        Text("\(channel)  (\(WifiChannels.band(of: channel) == .ghz5 ? "5" : "2.4") GHz)").tag(channel)
                    }
                }
                .onChange(of: channel) { _, new in
                    // Setting the channel on appear must not re-plan a running survey.
                    if model.role(of: board) != .fixedChannel(new) { choose(.fixedChannel(new)) }
                }
            }
        } header: {
            Text("Role")
        } footer: {
            Text(model.survey.isRunning ? "Changes apply right away." : "Applies when a survey starts.")
        }
        .panelRows()
        .onAppear {
            if case .fixedChannel(let current) = current { channel = current }
        }
    }

    private func choose(_ role: BoardRolePreference) {
        Task { await model.setRole(role, for: board) }
    }
}

/// The role picker as a sheet, from a board chip on the Survey screen.
struct BoardRoleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let board: BoardID

    var body: some View {
        NavigationStack {
            List {
                BoardRolePicker(board: board)
                Section {
                    Button("Board details") {
                        dismiss()
                        model.surveyPath.append(.board(board))
                    }
                }
                .panelRows()
            }
            .themedList()
            .navigationTitle(model.boardName(board))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// A board for `sheet(item:)`.
struct BoardSelection: Identifiable {
    let board: BoardID
    var id: String { board.description }
}
