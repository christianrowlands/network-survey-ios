import BoardKit
import BoardProtocol
import SwiftUI

/// One Scout: its state and any problem with the fix, what it is, its role,
/// firmware update, connect or disconnect, Remove, and erasing its pairings.
struct BoardDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let board: BoardID
    @State private var busy = false
    @State private var message: String?
    @State private var confirmingRemove = false
    @State private var confirmingErase = false
    /// The Settings > Bluetooth walkthrough; `reconnect` false after an erase.
    @State private var forgetGuide: ForgetGuide?
    /// Close this screen when the walkthrough closes (the Scout is gone).
    @State private var leaveAfterGuide = false
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
                    LabeledContent("Battery", value: BoardBattery.percent(status).map { "\($0)% (\(status.batteryMv) mV)" } ?? "None, USB powered")
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
                Section("Scout") {
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
                    Text("This is the only Scout in the running survey. Stop the survey to disconnect it.")
                }
            }
            .panelRows()

            Section {
                Button(model.isDemo(board) ? "Remove demo Scout" : "Remove Scout", role: .destructive) { confirmingRemove = true }
                    .disabled(busy)
                    .accessibilityIdentifier("board.forget")
            } footer: {
                Text(model.isDemo(board)
                     ? "Disconnects the demo Scout."
                     : "Network Survey stops connecting to it. It stays paired, so you can add it back from Scouts at any time without pairing again.")
            }
            .panelRows()

            Section {
                NavigationLink(value: SurveyRoute.firmwareUpdate(board)) {
                    Label("Install firmware from file", systemImage: "doc.badge.arrow.up")
                }
                if !model.isDemo(board) && state?.connection.isConnected == true {
                    Button("Erase pairings on the Scout", role: .destructive) { confirmingErase = true }
                        .disabled(busy || model.survey.isLocked)
                        .accessibilityIdentifier("board.erasePairings")
                }
            } header: {
                Text("Advanced")
            } footer: {
                if !model.isDemo(board) && state?.connection.isConnected == true {
                    Text("Only needed before giving the Scout away for good. To pair it with another phone, holding its BOOT button for 3 seconds is enough.")
                }
            }
            .panelRows()
        }
        .themedList()
        .navigationTitle(name)
        .alert("Scout", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .task(id: state?.info?.firmwareVersion) { await checkRelease() }
        .confirmationDialog("Remove \(name)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task { await remove() }
            }
        } message: {
            Text(model.isDemo(board)
                 ? "The demo Scout is disconnected."
                 : "Network Survey stops connecting to \(name). Add it back from Scouts whenever you like, with no pairing needed.")
        }
        .confirmationDialog("Erase pairings on \(name)?", isPresented: $confirmingErase, titleVisibility: .visible) {
            Button("Erase pairings", role: .destructive) {
                Task { await erasePairings(name: name) }
            }
        } message: {
            Text("\(name) forgets every phone it was paired with, including this iPhone. To use it here again, iOS must also forget it in Settings > Bluetooth.")
        }
        .sheet(item: $forgetGuide, onDismiss: { if leaveAfterGuide { dismiss() } }) { guide in
            ForgetPairingSheet(board: board, name: guide.name, reconnect: guide.reconnect)
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
                Button("Show me how") { forgetGuide = ForgetGuide(name: name, reconnect: true) }
                    .accessibilityIdentifier("board.fixPairing")
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
        case .bondMissing: "Pair this Scout again"
        case .pairingRejected: "Pairing did not finish"
        case .incompatible: "Firmware update needed"
        case .configureFailed: "The Scout could not start"
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

    private func remove() async {
        busy = true
        await model.forget(board)
        busy = false
        dismiss()
    }

    private func erasePairings(name: String) async {
        busy = true
        let confirmed = await model.forget(board, wipeBonds: true)
        busy = false
        if confirmed {
            leaveAfterGuide = true
            forgetGuide = ForgetGuide(name: name, reconnect: false)
        } else {
            message = "\(name) did not confirm, so it may still have its pairings. Keep it next to your iPhone and try again."
        }
    }
}

/// Which Settings > Bluetooth walkthrough to show.
private struct ForgetGuide: Identifiable {
    /// The advertised name, as Settings > Bluetooth lists it.
    let name: String
    let reconnect: Bool
    var id: Bool { reconnect }
}
