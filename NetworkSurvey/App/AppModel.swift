import BoardKit
import CoreBluetooth
import Destinations
import Foundation
import Observation
import OSLog
import SurveyCore

enum AppTab: Hashable {
    case survey, map, lists, files, settings
}

/// Screens pushed on the Survey tab's navigation stack.
enum SurveyRoute: Hashable {
    case boards
    case board(BoardID)
    case firmwareUpdate(BoardID)
    #if DEBUG
    /// Live records from the demo board (Debug builds only).
    case debugRecords
    #endif
    /// Design review of the Live Activity layouts (launch argument only).
    case liveActivityPreview
}

/// A Settings page another screen asks to open ("Set up" on a destination row).
/// The Settings screen shows it and sets `AppModel.settingsRoute` back to nil.
enum SettingsRoute: Hashable {
    case logFiles, mqtt, grpc, nsAnalytics
}

/// The composition root: builds the board manager (Bluetooth plus the demo
/// board), the survey session and its destinations, the shared NS Analytics
/// uploader, location and battery, and holds app-wide UI state.
@MainActor
@Observable
final class AppModel {
    static let backgroundUploadIdentifier = "app.networksurvey.ios.ns-analytics-upload"
    static let bluetoothRestoreIdentifier = "app.networksurvey.ios.boards"

    let options: LaunchOptions
    let settings: SettingsStore
    let store: SurveyStore
    let identity: DeviceIdentity
    /// Documents: survey folders are created under `Surveys/`.
    let filesRoot: URL
    let transport: CombinedBoardTransport
    let demoTransport: SimulatedBoardTransport
    let boardManager: BoardManager
    let phoneLocation: CoreLocationProvider
    let location: SurveyLocationProvider
    let controller: SurveySessionController
    let survey: SurveyModel
    let nsAnalyticsCredentials: any NSAnalyticsCredentialStore
    let nsAnalyticsClient: NSAnalyticsClient
    let uploader: NSAnalyticsUploader
    let access: AccessModel
    let idleTimer = IdleTimerController()

    var selectedTab: AppTab = .survey
    var surveyPath: [SurveyRoute] = []
    var settingsRoute: SettingsRoute?
    /// A short message for the user (a failed start, an upload result).
    var notice: String?
    var demoBoardEnabled: Bool
    /// The first-launch welcome is on screen.
    var showingWelcome: Bool
    /// An NS Analytics registration link opened from outside the app, for the
    /// registration screen to pick up (and set back to nil).
    var pendingRegistrationLink: URL?
    /// A survey a previous launch left running, offered for resume or close.
    var interruptedSession: SessionRow?
    var isResuming = false
    var nsAnalyticsState: NSAnalyticsUploader.State?
    var isUploading = false
    var isScreenActive = true
    /// Set when the survey database or the upload queue could not be opened from
    /// disk. The app still opens (in memory), but Start is blocked.
    let storageProblem: String?

    @ObservationIgnored let liveActivity = LiveActivityController()
    /// Records lost by boards so far and when that number last grew.
    @ObservationIgnored var lostRecords = (total: 0, grewAt: Date.distantPast)
    /// Stop in progress: the Live Activity is ended by `stopSurvey` with the final totals.
    @ObservationIgnored var isStoppingSurvey = false
    @ObservationIgnored let uploadTransport: BackgroundUploadTransport?
    @ObservationIgnored let roleStore: BoardRoleStore
    @ObservationIgnored var bluetoothTransport: BLEBoardTransport?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var launched = false

    static let log = Logger(subsystem: "app.networksurvey.ios", category: "app")

    /// `sharedStore` (tests) replaces the in-memory store of a UI-testing model.
    init(options: LaunchOptions = LaunchOptions(defaults: .standard), sharedStore: SurveyStore? = nil) {
        self.options = options
        var storageProblems: [String] = []
        let fileManager = FileManager.default
        let support = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        let defaults: UserDefaults
        if options.uiTesting {
            settings = .inMemory()
            settings[Settings.demoBoardEnabled] = true
            store = sharedStore ?? Self.memoryStore()
            filesRoot = fileManager.temporaryDirectory.appendingPathComponent("ui-tests", isDirectory: true)
            defaults = UserDefaults(suiteName: "ui-tests") ?? .standard
            defaults.removePersistentDomain(forName: "ui-tests")
        } else {
            settings = SettingsStore()
            do {
                store = try SurveyStore(url: support.appendingPathComponent("survey.sqlite"))
            } catch {
                Self.log.error("Survey database not opened: \(error.localizedDescription, privacy: .public)")
                storageProblems.append("The survey database could not be opened: \(error.localizedDescription)")
                store = Self.memoryStore()
            }
            filesRoot = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            defaults = .standard
        }
        roleStore = BoardRoleStore(defaults: defaults)
        identity = DeviceIdentity.load(from: settings)
        let demoEnabled = settings[Settings.demoBoardEnabled]
        demoBoardEnabled = demoEnabled
        showingWelcome = !settings[Settings.hasSeenWelcome] && (!options.uiTesting || options.showWelcome)

        let demo = SimulatedBoardTransport(boardCount: options.demoBoards, seed: options.demoSeed)
        demoTransport = demo
        transport = CombinedBoardTransport(demo: demo, demoEnabled: demoEnabled)
        let manager = BoardManager(transport: transport)
        boardManager = manager
        let demoIDs = transport.demoIDs

        phoneLocation = CoreLocationProvider()
        location = SurveyLocationProvider(phone: phoneLocation, demo: SimulatedLocationProvider()) { [simulatedWalk = options.simulatedWalk] in
            if simulatedWalk { return true }
            return await MainActor.run { !manager.readyBoards.isEmpty && manager.readyBoards.allSatisfy(demoIDs.contains) }
        }

        // NS Analytics: one uploader for every session, so uploads continue after Stop.
        nsAnalyticsCredentials = SettingsCredentialStore(settings: settings, deviceID: identity.deviceSerialNumber)
        if options.uiTesting {
            uploadTransport = nil
        } else {
            uploadTransport = BackgroundUploadTransport(configuration: .background(withIdentifier: Self.backgroundUploadIdentifier))
        }
        let httpTransport: any NSAnalyticsTransport = uploadTransport ?? URLSessionTransport()
        let queue: NSAnalyticsQueue
        do {
            queue = try NSAnalyticsQueue(url: options.uiTesting ? nil : NSAnalyticsQueue.defaultURL())
        } catch {
            Self.log.error("Upload queue not opened: \(error.localizedDescription, privacy: .public)")
            storageProblems.append("The NS Analytics upload queue could not be opened: \(error.localizedDescription)")
            // An in-memory queue cannot fail to open.
            queue = try! NSAnalyticsQueue(url: nil)
        }
        uploader = NSAnalyticsUploader(queue: queue, credentials: nsAnalyticsCredentials, transport: httpTransport)
        nsAnalyticsClient = NSAnalyticsClient(transport: httpTransport)

        storageProblem = storageProblems.isEmpty ? nil : storageProblems.joined(separator: " ")
        let settings = settings
        let uploader = uploader
        let environment = SessionEnvironment(
            boards: BoardManagerSource(manager: manager), location: location, store: store, settings: settings,
            identity: identity, app: AppInfo(appVersion: Bundle.main.shortVersion), filesRoot: filesRoot,
            battery: DeviceBattery(),
            makeSinks: { context in
                let startsWithDemo = await MainActor.run { manager.readyBoards.contains(where: demoIDs.contains) }
                return DestinationFactory.make(
                    context, settings: settings, uploader: uploader,
                    demoBoards: Set(demoIDs.map(\.description)), startsWithDemo: startsWithDemo
                )
            },
            isDemoSession: {
                await MainActor.run { manager.readyBoards.contains(where: demoIDs.contains) }
            }
        )
        controller = SurveySessionController(environment: environment)
        survey = SurveyModel(controller: controller, store: store, boardManager: manager)
        access = AccessModel(locationProvider: phoneLocation)

        if let uploadTransport {
            uploadTransport.orphanHandler = { taskID, result in
                Task { _ = await uploader.completeBackgroundUpload(taskID: taskID, result: result) }
            }
        }
    }

    private static func memoryStore() -> SurveyStore {
        // An in-memory database cannot fail to open; this only runs if the file database could not.
        try! SurveyStore.inMemory()
    }

    var demoBoardIDs: Set<BoardID> { transport.demoIDs }

    func isDemo(_ board: BoardID) -> Bool {
        transport.isDemo(board)
    }

    // MARK: - Launch

    /// Runs once per process. `restoredByBluetooth` is true when the system
    /// relaunched the app for Bluetooth state restoration: a survey that was
    /// running then resumes on its own.
    func launch(restoredByBluetooth: Bool) async {
        guard !launched else { return }
        launched = true
        tasks.append(Task { [weak self] in await self?.watchSettings() })
        tasks.append(Task { [weak self] in await self?.tick() })
        for (board, role) in roleStore.load() {
            await boardManager.setRole(role, for: board)
        }
        if !options.uiTesting && CBManager.authorization == .allowedAlways {
            await setUpBluetooth()
        }
        await access.refresh()
        await reconcileInterruptedSession(autoResume: restoredByBluetooth)
        if let storageProblem { notice = storageProblem }
        await applyLaunchOptions()
    }

    /// Creates the Bluetooth transport, which asks for Bluetooth access the
    /// first time, and reconnects boards this phone paired with before.
    func setUpBluetooth() async {
        guard bluetoothTransport == nil, !options.uiTesting else { return }
        let ble = BLEBoardTransport.coreBluetooth(restoreIdentifier: Self.bluetoothRestoreIdentifier)
        bluetoothTransport = ble
        access.powerState = { ble.central.powerState }
        await transport.attachBluetooth(ble)
        await boardManager.reconnectKnownBoards()
        await access.refresh()
    }

    func scenePhaseChanged(active: Bool) {
        isScreenActive = active
        Task { await access.refresh() }
        updateIdleTimer()
        // A Live Activity can only start in the foreground (after a background resume).
        if active { syncLiveActivity() }
    }

    func open(_ route: SettingsRoute) {
        settingsRoute = route
        selectedTab = .settings
    }

    func openBoards() {
        selectedTab = .survey
        surveyPath = [.boards]
    }

    /// Closes the welcome for good (until Settings > Help > Show welcome again).
    func finishWelcome() {
        settings[Settings.hasSeenWelcome] = true
        showingWelcome = false
    }

    // MARK: - Demo board

    func setDemoBoardEnabled(_ enabled: Bool) async {
        if settings[Settings.demoBoardEnabled] != enabled { settings[Settings.demoBoardEnabled] = enabled }
        guard demoBoardEnabled != enabled || !enabled else { return }
        demoBoardEnabled = enabled
        if !enabled {
            for board in demoBoardIDs where boardManager.boards[board] != nil {
                await boardManager.disconnect(board)
            }
        }
        await transport.setDemoEnabled(enabled)
    }

    // MARK: - Loops

    /// Follows settings changed elsewhere (the Settings screen's demo and crash report switches).
    private func watchSettings() async {
        for await name in settings.changes() {
            switch name {
            case Settings.demoBoardEnabled.name:
                let enabled = settings[Settings.demoBoardEnabled]
                if enabled != demoBoardEnabled { await setDemoBoardEnabled(enabled) }
            case Settings.crashReports.name:
                CrashReportingController.apply(enabled: settings[Settings.crashReports])
            default:
                break
            }
        }
    }

    /// Once a second: Live Activity, idle timer, access and upload state.
    private func tick() async {
        var count = 0
        while !Task.isCancelled {
            syncLiveActivity()
            updateIdleTimer()
            if count % 3 == 0 && isScreenActive { await access.refresh() }
            if count % 5 == 0 { nsAnalyticsState = await uploader.state() }
            count += 1
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func updateIdleTimer() {
        // Keep the screen on while a survey shows on screen; locking still works.
        idleTimer.set("survey", held: survey.isRunning && isScreenActive && selectedTab == .survey)
    }

    private func applyLaunchOptions() async {
        if options.autoConnectDemo {
            for board in demoBoardIDs.sorted(by: { $0.description < $1.description }) {
                _ = try? await boardManager.connect(board)
            }
        }
        if options.autoStartSurvey { await startSurvey() }
        switch options.openScreen {
        case "boards": surveyPath = [.boards]
        case "board": surveyPath = demoTransport.profiles.first.map { [.boards, .board($0.id)] } ?? []
        #if DEBUG
        case "debugRecords": surveyPath = [.debugRecords]
        #endif
        case "liveActivity": surveyPath = [.liveActivityPreview]
        default: break
        }
    }
}

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}
