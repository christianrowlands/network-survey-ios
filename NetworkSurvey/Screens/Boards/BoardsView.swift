import BoardKit
import BoardProtocol
import SwiftUI

/// Your Scouts and Scouts nearby. Opening this screen sets up Bluetooth (iOS
/// asks for access the first time) and scans while it is visible, for up to
/// `scanLimit`.
struct BoardsView: View {
    @Environment(AppModel.self) private var model
    @State private var known: [KnownBoard] = []
    @State private var connecting: BoardID?
    @State private var message: String?
    /// Nothing found after scanning a while.
    @State private var searchedLong = false
    @State private var scanning = true
    /// Bumped by Scan again to restart the scan task.
    @State private var scanRun = 0
    @State private var showingGuide = false
    /// A Scout whose connect failed on a stale pairing, for the Settings walkthrough.
    @State private var pairingFix: PairingFix?

    private static let scanLimit: Duration = .seconds(30)

    var body: some View {
        List {
            if let notice = bluetoothNotice {
                Section {
                    notice
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            if yourBoards.isEmpty {
                guideSection
            } else {
                yourBoardsSection
            }
            nearbySection
            demoSection
            if !yourBoards.isEmpty {
                guideSection
            }
        }
        .themedList()
        .navigationTitle("Scouts")
        .sheet(isPresented: $showingGuide) { ScoutGuideView() }
        .sheet(item: $pairingFix, onDismiss: { scanRun += 1 }) { fix in
            ForgetPairingSheet(board: fix.board, name: fix.name)
        }
        .alert("Could not connect", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .task(id: scanRun) {
            await model.setUpBluetooth()
            scanning = true
            searchedLong = false
            await model.boardManager.startScanning()
            known = await model.boardManager.knownBoards()
            try? await Task.sleep(for: .seconds(10))
            searchedLong = true
            try? await Task.sleep(for: Self.scanLimit - .seconds(10))
            guard !Task.isCancelled, connecting == nil else { return }
            await model.boardManager.stopScanning()
            scanning = false
        }
        .onChange(of: model.boardManager.boards.count) {
            Task { known = await model.boardManager.knownBoards() }
        }
        .onDisappear {
            Task { await model.boardManager.stopScanning() }
        }
    }

    private var guideSection: some View {
        Section {
            Button {
                showingGuide = true
            } label: {
                InfoRow(
                    symbol: "questionmark.circle", symbolColor: Theme.Colors.accentInk,
                    title: yourBoards.isEmpty ? "New to NS Scout?" : "About NS Scout",
                    detail: ["What it is, where to get one, and how to set it up"]
                ) {
                    Image(systemName: "chevron.right").foregroundStyle(Theme.Colors.ink3)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("boards.guide")
        }
        .panelRows()
    }

    private var yourBoardsSection: some View {
        Section("Your Scouts") {
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
            if nearby.isEmpty {
                Text(searchedLong
                     ? "No Scouts found. Check that it is plugged in (its light blinks) and within a few meters. A fast cyan blink means it is ready to pair."
                     : "Plug in your Scout and hold it next to your iPhone.")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.ink2)
                    .frame(minHeight: Theme.Spacing.touchTarget)
                    .accessibilityIdentifier("boards.nearbyEmpty")
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
                if scanning {
                    ProgressView().controlSize(.small)
                    Text("Looking for Scouts")
                } else {
                    Button("Scan again") { scanRun += 1 }
                        .font(Theme.Fonts.label)
                        .textCase(nil)
                        .accessibilityIdentifier("boards.scanAgain")
                }
            }
            .accessibilityElement(children: scanning ? .combine : .contain)
        } footer: {
            Text(nearbyFooter)
        }
        .panelRows()
    }

    private var nearbyFooter: String {
        if let connecting, !model.isDemo(connecting) {
            return "When iOS asks, tap Pair. Keep the Scout next to your iPhone until it connects."
        }
        return "Tap a Scout to connect. New Scouts are ready to pair. To pair one that was used with another phone, hold its BOOT button for 3 seconds."
    }

    private var demoSection: some View {
        Section {
            Toggle("Demo Scout", isOn: Binding(
                get: { model.demoBoardEnabled },
                set: { enabled in Task { await model.setDemoBoardEnabled(enabled) } }
            ))
            .tint(Theme.Colors.accent)
            .disabled(model.survey.isLocked)
            .accessibilityIdentifier("boards.demoToggle")
        } footer: {
            Text(model.survey.isLocked
                 ? "Stop the survey to turn the demo Scout on or off."
                 : "A simulated Scout, so you can try the app without hardware. Everything it reports is made up, and it is never sent to NS Analytics.")
        }
        .panelRows()
    }

    /// Scouts in use or paired with this iPhone (not removed).
    private var yourBoards: [BoardID] {
        let inUse = model.boardsInUse
        let knownIDs = known.map(\.id).filter { !inUse.contains($0) && (!model.isDemo($0) || model.demoBoardEnabled) }
        let others = model.boardManager.boards.filter { $0.value.issue != nil }.map(\.key)
            .filter { !inUse.contains($0) && !knownIDs.contains($0) }
        return inUse + knownIDs + others
    }

    /// Scouts advertising nearby that are not in use, strongest first.
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
                        message: "Turn on Bluetooth in Control Center to find your Scout. The demo Scout works without it.",
                        tone: .danger) { AnyView(EmptyView()) }
        case .denied, .restricted:
            NoticePanel(symbol: "bolt.horizontal.circle", title: "Bluetooth access is off",
                        message: "Network Survey needs Bluetooth to talk to your Scout. Tap Open Settings and turn on Bluetooth.",
                        tone: .danger) {
                AnyView(Button("Open Settings") { AccessModel.openAppSettings() })
            }
        case .unsupported:
            NoticePanel(symbol: "bolt.horizontal.circle", title: "Bluetooth is not available",
                        message: "This device can't connect to a Scout. The demo Scout still works.", tone: .danger) {
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
            if model.boardManager.boards[board]?.issue == .bondMissing {
                pairingFix = PairingFix(board: board, name: model.boardName(board))
            } else {
                message = failure
            }
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
        .accessibilityHint(board.blocked ? "" : "Connects to the Scout")
    }

    private var stateText: String {
        if isConnecting { return board.isSimulated ? "Connecting" : "Pairing, tap Pair when iOS asks" }
        if board.isSimulated { return "Simulated Scout · \(distance)" }
        if board.blocked { return "Paired with another phone. Hold its BOOT button for 3 seconds to pair it here." }
        if board.isRemoved && board.wasReset { return "Was reset since you used it · \(distance)" }
        if board.isRemoved { return "Used with this iPhone before · \(distance)" }
        if board.isKnown { return "Paired with this iPhone · \(distance)" }
        if board.pairingMode { return "Ready to pair · \(distance)" }
        return "Hold its BOOT button 3 seconds to pair · \(distance)"
    }

    /// Signal strength in words.
    private var distance: String {
        if board.rssi >= -60 { return "Very close" }
        return board.rssi >= -75 ? "Nearby" : "Weak signal"
    }

    /// 0 at -95 dBm or weaker, 1 at -45 dBm or stronger.
    private var signalLevel: Double {
        min(max((Double(board.rssi) + 95) / 50, 0), 1)
    }
}

private struct PairingFix: Identifiable {
    let board: BoardID
    let name: String
    var id: BoardID { board }
}
