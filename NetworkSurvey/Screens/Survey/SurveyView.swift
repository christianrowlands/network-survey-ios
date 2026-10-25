import BoardKit
import SurveyCore
import SwiftUI

/// Home screen, modeled on the Network Survey Android app's survey screen.
/// Ready shows the two questions above Start; Recording shows the live survey
/// above Stop. The one main action sits in a pinned bar at the bottom.
struct SurveyView: View {
    @Environment(AppModel.self) private var model
    @State private var setup = SurveySetup()
    @State private var confirmingStop = false
    @State private var roleBoard: BoardSelection?
    @State private var stopGuarded = false

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.surveyPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    notices
                    if isRecording {
                        SurveyRecordingBody { roleBoard = BoardSelection(board: $0) }
                            .transition(.opacity)
                    } else {
                        SurveyReadyBody(setup: currentSetup) { roleBoard = BoardSelection(board: $0) }
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: isRecording)
                .padding(.horizontal, Theme.Spacing.screenGutter)
                .padding(.bottom, Theme.Spacing.l)
                .frame(maxWidth: Theme.Spacing.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .screenBackground()
            .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
            .navigationTitle("Network Survey")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BrandTile(size: 30)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: SurveyRoute.boards) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "sensor")
                            Text("Scouts")
                        }
                    }
                    .accessibilityIdentifier("survey.boardsButton")
                }
            }
            .navigationDestination(for: SurveyRoute.self) { route in
                switch route {
                case .boards: BoardsView()
                case .board(let board): BoardDetailView(board: board)
                case .firmwareUpdate(let board): FirmwareUpdateScreen(boardID: board)
                #if DEBUG
                case .debugRecords: DebugRecordsView()
                #endif
                case .liveActivityPreview: LiveActivityPreview()
                }
            }
            .sheet(item: $roleBoard) { selection in
                BoardRoleSheet(board: selection.board)
            }
            .task { await followSettings() }
            .onChange(of: model.survey.isRunning) { _, running in
                // A double tap on Start must not land on Stop.
                guard running else { return }
                stopGuarded = true
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    stopGuarded = false
                }
            }
        }
    }

    private var isRecording: Bool {
        model.survey.state == .running || model.survey.state == .stopping
    }

    // MARK: - Notices

    @ViewBuilder private var notices: some View {
        if let row = model.interruptedSession, !isRecording {
            NoticePanel(
                symbol: "exclamationmark.arrow.circlepath",
                title: "Your last survey was cut off",
                message: "It started \(row.startedAt.formatted(date: .abbreviated, time: .shortened)) and stopped when the app closed. Resume it to keep the same mission ID, or end it.",
                tone: .warning
            ) {
                Button(model.isResuming ? "Resuming" : "Resume") {
                    Task { await model.resumeInterrupted() }
                }
                .disabled(model.isResuming)
                .accessibilityIdentifier("survey.resume")
                Button("End it", role: .destructive) {
                    Task { await model.endInterrupted() }
                }
            }
            .padding(.top, Theme.Spacing.s)
        }
        if !isRecording && model.survey.stopReason == .lowDiskSpace {
            NoticePanel(
                symbol: "externaldrive.badge.exclamationmark", title: "The survey stopped on its own",
                message: "This iPhone is almost out of storage. Free up space before starting another survey.",
                tone: .danger
            ) { EmptyView() }
            .padding(.top, Theme.Spacing.s)
        }
        if let issue = model.survey.issue {
            NoticePanel(symbol: "exclamationmark.triangle", title: "Survey problem", message: issue, tone: .warning) {
                EmptyView()
            }
            .padding(.top, Theme.Spacing.s)
        }
        if let notice = model.notice {
            NoticePanel(symbol: "info.circle", title: "Note", message: notice, tone: .info) {
                Button("Dismiss") { model.notice = nil }
            }
            .padding(.top, Theme.Spacing.s)
            .accessibilityIdentifier("survey.notice")
        }
    }

    // MARK: - Start and Stop

    private var actionBar: some View {
        ActionBar {
            if isRecording {
                Button {
                    confirmingStop = true
                } label: {
                    Label(model.survey.state == .stopping ? "Stopping" : "Stop survey", systemImage: "stop.fill")
                }
                .buttonStyle(StopButtonStyle())
                .disabled(model.survey.state == .stopping || stopGuarded)
                .accessibilityIdentifier("survey.stop")
                .confirmationDialog("Stop this survey?", isPresented: $confirmingStop, titleVisibility: .visible) {
                    Button("Stop survey", role: .destructive) {
                        Task { await model.stopSurvey() }
                    }
                    .accessibilityIdentifier("survey.confirmStop")
                    Button("Keep recording", role: .cancel) {}
                } message: {
                    Text(stopMessage)
                }
            } else {
                let block = startBlock
                if let block {
                    Text(block.message)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.Colors.amberText)
                        .accessibilityIdentifier("survey.startBlock")
                }
                Button {
                    Task { await model.startSurvey() }
                } label: {
                    if model.survey.state == .starting {
                        HStack(spacing: Theme.Spacing.s) {
                            ProgressView().tint(Theme.Colors.onAccent)
                            Text("Starting")
                        }
                    } else {
                        Label("Start survey", systemImage: "play.fill")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(block != nil || model.survey.state != .idle)
                .accessibilityValue(block?.message ?? "")
                .accessibilityIdentifier("survey.start")
            }
        }
    }

    private var startBlock: StartBlock? {
        let manager = model.boardManager
        let ready = manager.readyBoards
        let incompatible = manager.boards.first { if case .incompatible = $0.value.compatibility { true } else { false } }
        return StartBlock.evaluate(
            setup: currentSetup, readyBoards: ready.count, realBoardsReady: ready.contains { !model.isDemo($0) },
            incompatibleBoard: incompatible.map { model.boardName($0.key) },
            bluetooth: model.access.bluetooth, location: model.access.location,
            storageAvailable: model.storageProblem == nil
        )
    }

    /// The settings' setup, with NS Analytics unavailable while a demo board is in use.
    private var currentSetup: SurveySetup {
        var current = setup
        if model.boardManager.readyBoards.contains(where: model.isDemo) {
            current.unavailable[.nsAnalytics] = "Not available with the demo Scout"
        }
        return current
    }

    private var stopMessage: String {
        var message = "The Scouts stop recording and the files are closed."
        if model.survey.destinations.contains(where: { $0.name == "nsAnalytics" }) {
            message += " Records waiting for NS Analytics keep uploading."
        }
        return message
    }

    // MARK: - Settings

    private func followSettings() async {
        reloadSetup()
        for await _ in model.settings.changes() {
            reloadSetup()
        }
    }

    private func reloadSetup() {
        let registered = model.nsAnalyticsCredentials.load() != nil
        setup = SurveySetup.read(model.settings, registered: registered)
    }
}
