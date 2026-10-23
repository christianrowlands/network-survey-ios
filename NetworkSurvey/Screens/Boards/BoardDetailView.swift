import BoardKit
import BoardProtocol
import SwiftUI

/// One board: its state and any problem with the fix, what it is, its role,
/// firmware update, connect or disconnect, and Forget.
struct BoardDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let board: BoardID
    @State private var busy = false
    @State private var message: String?
    @State private var confirmingForget = false
    /// "Up to date" or "Update available", once the latest release was checked.
    @State private var releaseStatus: String?

    var body: some View {
        let state = model.boardManager.boards[board]
        let name = model.boardName(board)
        List {
            Section {
                HStack(spacing: Theme.Spacing.m) {
                    Dot(color: state?.isReady == true ? Theme.Colors.green : Theme.Colors.ink3, size: 10)
                    Text(BoardText.connection(state))
                        .font(Theme.Fonts.rowTitle)
                        .foregroundStyle(Theme.Colors.ink)
                        .accessibilityIdentifier("board.connection")
                    Spacer()
                    if model.isDemo(board) { TagPill(text: "Demo", color: Theme.Colors.accentInk) }
                }
                if let issue = state?.issue {
                    issueView(issue, name: name)
                }
            }
            .panelRows()

            if let status = state?.status, state?.connection.isConnected == true {
                Section("Now") {
                    LabeledContent("Battery", value: BoardBattery.percent(status).map { "\($0)% (\(status.batteryMv) mV)" } ?? "No battery info")
                    LabeledContent("Doing", value: BoardText.assignment(state?.assignment, status: status) ?? "Waiting for a survey")
                    if status.currentChannel > 0 {
                        LabeledContent("Channel now", value: "\(status.currentChannel)")
                    }
                    if state?.assignment != nil {
                        LabeledContent("Records", value: "\(status.recordsPerSec)/s")
                    }
                    let lost = (state?.counters.droppedRecords ?? 0) + (state?.counters.missedNotifications ?? 0)
                    LabeledContent("Records lost", value: lost.formatted())
                        .foregroundStyle(lost > 0 ? Theme.Colors.amberText : Theme.Colors.ink)
                }
                .monospacedDigit()
                .panelRows()
            }

            if let info = state?.info {
                Section("Board") {
                    LabeledContent("Model", value: BoardText.model(info))
                    LabeledContent("Firmware", value: firmwareText(info))
                        .accessibilityIdentifier("board.firmware")
                    LabeledContent("Protocol", value: "\(info.protocolMajor).\(info.protocolMinor)")
                    LabeledContent("Wi-Fi bands", value: BoardText.bands(info.bands))
                    LabeledContent("GPS", value: info.gpsPresent ? "Fitted" : "None")
                }
                .panelRows()
            }

            BoardRolePicker(board: board)

            Section {
                NavigationLink(value: SurveyRoute.firmwareUpdate(board)) {
                    Label("Update firmware", systemImage: "arrow.down.circle")
                }
                .accessibilityIdentifier("board.updateFirmware")
                if state?.connection.isConnected == true {
                    Button {
                        Task { await run { await model.disconnect(board) } }
                    } label: {
                        Text("Disconnect")
                    }
                    .disabled(busy || model.survey.isRunning && model.boardManager.readyBoards == [board])
                } else {
                    Button {
                        Task {
                            await run {
                                if let failure = await model.connect(board) { message = failure }
                            }
                        }
                    } label: {
                        Text(busy ? "Connecting" : "Connect")
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("board.connect")
                }
            } footer: {
                if model.survey.isRunning && model.boardManager.readyBoards == [board] {
                    Text("This is the only board in the running survey. Stop the survey to disconnect it.")
                }
            }
            .panelRows()

            Section {
                Button("Forget this board", role: .destructive) { confirmingForget = true }
                    .disabled(busy)
                    .accessibilityIdentifier("board.forget")
            } footer: {
                Text("The board deletes its pairing with this iPhone and is no longer reconnected.")
            }
            .panelRows()

            Section("Advanced") {
                NavigationLink(value: SurveyRoute.firmwareUpdate(board)) {
                    Label("Install firmware from file", systemImage: "doc.badge.arrow.up")
                }
            }
            .panelRows()
        }
        .themedList()
        .navigationTitle(name)
        .alert("Board", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .task(id: state?.info?.firmwareVersion) { await checkRelease() }
        .confirmationDialog("Forget \(name)?", isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("Forget board", role: .destructive) {
                Task { await forget(name: name) }
            }
        } message: {
            Text(model.isDemo(board)
                 ? "The demo board is disconnected and forgotten."
                 : "The board deletes its pairing with this iPhone. To pair again later, also open Settings > Bluetooth, tap the info button next to \(name) and choose Forget This Device.")
        }
    }

    @ViewBuilder
    private func issueView(_ issue: BoardIssue, name: String) -> some View {
        NoticePanel(
            symbol: "exclamationmark.triangle", title: issueTitle(issue),
            message: BoardText.issueMessage(issue, name: name), tone: .danger
        ) {
            switch issue {
            case .bondMissing:
                Button("Open Settings") { AccessModel.openAppSettings() }
            case .incompatible:
                NavigationLink("Update firmware", value: SurveyRoute.firmwareUpdate(board))
            case .pairingRejected, .configureFailed:
                EmptyView()
            }
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    private func issueTitle(_ issue: BoardIssue) -> String {
        switch issue {
        case .bondMissing: "Forget the board in iOS Settings"
        case .pairingRejected: "Pairing did not finish"
        case .incompatible: "Firmware update needed"
        case .configureFailed: "The board could not start"
        }
    }

    private func firmwareText(_ info: NSBBoardInfo) -> String {
        let version = info.firmwareVersion.isEmpty ? "Unknown" : info.firmwareVersion
        return releaseStatus.map { "\(version) · \($0)" } ?? version
    }

    /// Compares the board's firmware with the latest release. Shows nothing
    /// extra when that can't be checked (offline, demo board, unknown version).
    private func checkRelease() async {
        releaseStatus = nil
        guard !model.isDemo(board), let info = model.boardManager.boards[board]?.info,
              !info.firmwareVersion.isEmpty else { return }
        releaseStatus = await FirmwareUpdateModel.releaseStatus(for: info)
    }

    private func run(_ work: () async -> Void) async {
        busy = true
        await work()
        busy = false
    }

    private func forget(name: String) async {
        busy = true
        let confirmed = await model.forget(board)
        busy = false
        if !model.isDemo(board) {
            model.notice = confirmed
                ? "\(name) deleted its pairing. Before pairing again, open Settings > Bluetooth and choose Forget This Device for \(name)."
                : "\(name) was forgotten on this iPhone. It was not connected, so it still holds its pairing: hold its BOOT button for 10 seconds while it starts to clear it."
        }
        dismiss()
    }
}
