import BoardKit
import BoardProtocol
import SwiftUI

/// Your boards and boards nearby. Opening this screen sets up Bluetooth (iOS
/// asks for access the first time) and scans while it is visible.
struct BoardsView: View {
    @Environment(AppModel.self) private var model
    @State private var known: [KnownBoard] = []
    @State private var connecting: BoardID?
    @State private var message: String?
    /// Nothing found after scanning a while.
    @State private var searchedLong = false

    var body: some View {
        List {
            if let notice = bluetoothNotice {
                Section {
                    notice
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            if !yourBoards.isEmpty {
                yourBoardsSection
            }
            nearbySection
            demoSection
        }
        .themedList()
        .navigationTitle("Boards")
        .alert("Could not connect", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .task {
            await model.setUpBluetooth()
            await model.boardManager.startScanning()
            known = await model.boardManager.knownBoards()
            try? await Task.sleep(for: .seconds(10))
            searchedLong = true
        }
        .onChange(of: model.boardManager.boards.count) {
            Task { known = await model.boardManager.knownBoards() }
        }
        .onDisappear {
            Task { await model.boardManager.stopScanning() }
        }
    }

    private var yourBoardsSection: some View {
        Section("Your boards") {
            ForEach(yourBoards, id: \.self) { board in
                NavigationLink(value: SurveyRoute.board(board)) {
                    YourBoardRow(board: board, known: known.first { $0.id == board })
                }
                .accessibilityIdentifier("boards.yours")
            }
        }
        .panelRows()
    }

    private var nearbySection: some View {
        Section {
            if nearby.isEmpty && searchedLong {
                Text("No boards nearby. Check that the board is powered and within a few meters.")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.ink2)
                    .frame(minHeight: Theme.Spacing.touchTarget)
            }
            ForEach(nearby) { board in
                Button {
                    Task { await connect(board.id) }
                } label: {
                    NearbyBoardRow(board: board, isConnecting: connecting == board.id)
                }
                .buttonStyle(.plain)
                .disabled(board.blocked || connecting != nil)
                .accessibilityIdentifier("boards.nearby")
            }
        } header: {
            HStack(spacing: Theme.Spacing.s) {
                Text("Nearby")
                Spacer()
                ProgressView().controlSize(.small)
                Text("Looking for boards")
            }
            .accessibilityElement(children: .combine)
        } footer: {
            Text(nearbyFooter)
        }
        .panelRows()
    }

    private var nearbyFooter: String {
        if let connecting, !model.isDemo(connecting) {
            return "When iOS asks, tap Pair. Keep the board next to your iPhone until it connects."
        }
        return "Hold the board next to your iPhone. New boards are ready to pair. To pair a board again, hold its BOOT button for 3 seconds."
    }

    private var demoSection: some View {
        Section {
            Toggle("Demo board", isOn: Binding(
                get: { model.demoBoardEnabled },
                set: { enabled in Task { await model.setDemoBoardEnabled(enabled) } }
            ))
            .tint(Theme.Colors.accent)
            .disabled(model.survey.isLocked)
            .accessibilityIdentifier("boards.demoToggle")
        } footer: {
            Text(model.survey.isLocked
                 ? "Stop the survey to turn the demo board on or off."
                 : "A simulated board, so you can try the app without hardware. Everything it reports is made up, and it is never sent to NS Analytics.")
        }
        .panelRows()
    }

    /// Boards in use or paired with this iPhone.
    private var yourBoards: [BoardID] {
        let inUse = model.boardsInUse
        let knownIDs = known.map(\.id).filter { !inUse.contains($0) && (!model.isDemo($0) || model.demoBoardEnabled) }
        let others = model.boardManager.boards.filter { $0.value.issue != nil }.map(\.key)
            .filter { !inUse.contains($0) && !knownIDs.contains($0) }
        return inUse + knownIDs + others
    }

    /// Boards advertising nearby that are not yours, strongest first.
    private var nearby: [DiscoveredBoard] {
        let yours = Set(yourBoards)
        return model.boardManager.discovered
            .filter { !yours.contains($0.id) }
            .sorted { $0.rssi > $1.rssi }
    }

    private var bluetoothNotice: NoticePanel<AnyView>? {
        switch model.access.bluetooth {
        case .off:
            NoticePanel(symbol: "bolt.horizontal.circle", title: "Bluetooth is off",
                        message: "Turn on Bluetooth in Control Center or Settings to find your board. The demo board works without it.",
                        tone: .danger) { AnyView(EmptyView()) }
        case .denied, .restricted:
            NoticePanel(symbol: "bolt.horizontal.circle", title: "Bluetooth access is off",
                        message: "Network Survey needs Bluetooth to talk to your board. Turn it on for Network Survey in Settings.",
                        tone: .danger) {
                AnyView(Button("Open Settings") { AccessModel.openAppSettings() })
            }
        case .unsupported:
            NoticePanel(symbol: "bolt.horizontal.circle", title: "Bluetooth is not available",
                        message: "This device can't connect to a board. The demo board still works.", tone: .danger) {
                AnyView(EmptyView())
            }
        case .notDetermined, .ready:
            nil
        }
    }

    private func connect(_ board: BoardID) async {
        connecting = board
        defer { connecting = nil }
        if let failure = await model.connect(board) {
            message = failure
        } else {
            known = await model.boardManager.knownBoards()
        }
    }
}

private struct YourBoardRow: View {
    @Environment(AppModel.self) private var model
    let board: BoardID
    let known: KnownBoard?

    var body: some View {
        let state = model.boardManager.boards[board]
        let connection = BoardText.connection(state)
        let ready = state?.isReady == true
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: "sensor.fill")
                .foregroundStyle(ready ? Theme.Colors.green : Theme.Colors.ink3)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(model.boardName(board))
                        .font(Theme.Fonts.rowTitle.weight(.medium))
                        .foregroundStyle(Theme.Colors.ink)
                    if model.isDemo(board) { TagPill(text: "Demo", color: Theme.Colors.accentInk) }
                }
                Text([state?.info.map(BoardText.model) ?? known?.modelName, connection].compactMap { $0 }.filter { !$0.isEmpty }
                    .joined(separator: " · "))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(state?.issue == nil ? Theme.Colors.ink2 : Theme.Colors.red)
            }
            Spacer()
            if let percent = state?.status.flatMap(BoardBattery.percent) {
                Label("\(percent)%", systemImage: BoardBattery.symbol(percent))
                    .font(Theme.Fonts.counter)
                    .foregroundStyle(Theme.Colors.ink2)
            }
        }
        .frame(minHeight: Theme.Spacing.touchTarget)
        .accessibilityElement(children: .combine)
    }
}

private extension DiscoveredBoard {
    /// Paired with another phone. The demo board is always available.
    var blocked: Bool { isUnavailable && !isSimulated }
}

private struct NearbyBoardRow: View {
    let board: DiscoveredBoard
    let isConnecting: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: "cellularbars", variableValue: signalLevel)
                .foregroundStyle(board.blocked ? Theme.Colors.ink3 : Theme.Colors.accentInk)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(board.name)
                        .font(Theme.Fonts.rowTitle.weight(.medium))
                        .foregroundStyle(board.blocked ? Theme.Colors.ink3 : Theme.Colors.ink)
                    if board.isSimulated { TagPill(text: "Demo", color: Theme.Colors.accentInk) }
                }
                Text(stateText)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.ink2)
            }
            Spacer()
            if isConnecting {
                ProgressView()
            } else if !board.blocked {
                Text(board.pairingMode || board.isKnown || board.isSimulated ? "Connect" : "")
                    .font(Theme.Fonts.body.weight(.semibold))
                    .foregroundStyle(Theme.Colors.accentInk)
            }
        }
        .frame(minHeight: Theme.Spacing.touchTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(board.blocked ? "" : "Connects to the board")
    }

    private var stateText: String {
        if isConnecting { return board.isSimulated ? "Connecting" : "Pairing, tap Pair when iOS asks" }
        if board.isSimulated { return "Simulated board · \(board.rssi) dBm" }
        if board.blocked { return "Paired with another phone. Hold its BOOT button for 3 seconds to pair it here." }
        if board.isKnown { return "Paired with this iPhone · \(board.rssi) dBm" }
        if board.pairingMode { return "Ready to pair · \(board.rssi) dBm" }
        return "Not in pairing mode · \(board.rssi) dBm"
    }

    /// 0 at -95 dBm or weaker, 1 at -45 dBm or stronger.
    private var signalLevel: Double {
        min(max((Double(board.rssi) + 95) / 50, 0), 1)
    }
}
