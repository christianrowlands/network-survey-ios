import BoardKit
import BoardProtocol
import Destinations
import Foundation

public enum SessionState: String, Sendable, Equatable {
    case idle, starting, running, stopping
}

public enum SessionError: Error, Equatable, Sendable {
    case notIdle
    case noBoardConnected
    case nothingToSurvey
    case boardStartFailed(String)
}

/// Why the last session stopped.
public enum StopReason: String, Sendable, Equatable {
    case user
    /// Free space fell below `SessionEnvironment.minimumFreeBytes`.
    case lowDiskSpace
}

/// What the UI sees of the session.
public struct SessionSnapshot: Sendable, Equatable {
    public var state: SessionState
    public var session: SessionRow?
    /// Last start failure, for display.
    public var lastError: SessionError?
    public var stopReason: StopReason? = nil
    /// Location authorization when the session started; anything other than
    /// When In Use means records carry no phone location.
    public var locationAuthorization: LocationAuthorization? = nil
    /// A problem worth showing that did not stop the survey (for example the
    /// end of the session could not be saved).
    public var issue: String? = nil
}

/// Everything a session talks to, injected so tests can use fakes.
public struct SessionEnvironment: Sendable {
    public var boards: any SurveyBoardSource
    public var location: any LocationProvider
    public var store: SurveyStore
    public var settings: SettingsStore
    public var identity: DeviceIdentity
    public var app: AppInfo
    /// Session folders are created under `<filesRoot>/Surveys/`, normally Documents.
    public var filesRoot: URL
    public var battery: any BatteryProvider
    /// Builds the enabled destinations for a session.
    public var makeSinks: @Sendable (SessionContext) async -> [any SurveyRecordSink]
    public var now: @Sendable () -> Date
    /// How often buffered records are written and sent.
    public var flushInterval: Duration
    /// Overrides `device_status_scan_interval_seconds` (tests).
    public var deviceStatusInterval: Duration?
    /// Time allowed after Stop for records already in flight.
    public var stopGrace: Duration
    /// How long Stop waits for each destination before moving on.
    public var sinkTimeout: Duration
    /// Free space (bytes) under which a running survey stops itself.
    public var minimumFreeBytes: Int64
    /// Free space where the files go; the default reads `filesRoot`'s volume.
    public var freeSpace: @Sendable () -> Int64?
    /// True when the survey about to start includes the Demo board; its
    /// missionId is then `MissionID.makeDemo`.
    public var isDemoSession: @Sendable () async -> Bool

    public init(
        boards: any SurveyBoardSource, location: any LocationProvider, store: SurveyStore, settings: SettingsStore,
        identity: DeviceIdentity, app: AppInfo, filesRoot: URL, battery: any BatteryProvider = UnknownBattery(),
        makeSinks: @escaping @Sendable (SessionContext) async -> [any SurveyRecordSink],
        now: @escaping @Sendable () -> Date = { Date() }, flushInterval: Duration = .seconds(1),
        deviceStatusInterval: Duration? = nil, stopGrace: Duration = .milliseconds(300),
        sinkTimeout: Duration = .seconds(10), minimumFreeBytes: Int64 = 200_000_000,
        freeSpace: (@Sendable () -> Int64?)? = nil, isDemoSession: @escaping @Sendable () async -> Bool = { false }
    ) {
        self.boards = boards
        self.location = location
        self.store = store
        self.settings = settings
        self.identity = identity
        self.app = app
        self.filesRoot = filesRoot
        self.battery = battery
        self.makeSinks = makeSinks
        self.now = now
        self.flushInterval = flushInterval
        self.deviceStatusInterval = deviceStatusInterval
        self.stopGrace = stopGrace
        self.sinkTimeout = sinkTimeout
        self.minimumFreeBytes = minimumFreeBytes
        self.freeSpace = freeSpace ?? { [filesRoot] in Self.availableBytes(at: filesRoot) }
        self.isDemoSession = isDemoSession
    }

    static func availableBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
    }
}

/// The session lifecycle: idle, starting, running, stopping, idle.
///
/// Start needs at least one ready board (Hello and SetTime done). The plan
/// (protocols and destinations) is read from settings once and stays fixed
/// while running. A board that drops mid-survey opens a gap event that closes
/// when it is back; the session and missionId carry on. Resume after a
/// relaunch does not wait for boards: location, destinations and timers start
/// at once and the boards join when they are ready again.
public actor SurveySessionController {
    let env: SessionEnvironment
    var state = SessionState.idle
    var session: SessionRow?
    var lastError: SessionError?
    var stopReason: StopReason?
    var locationAuthorization: LocationAuthorization?
    var issue: String?
    var pipeline: RecordPipeline?
    /// The last session's counters after its final flush, for the screens after Stop.
    var finalCounters: PipelineCounters?
    var sinks: [any SurveyRecordSink] = []
    var tasks: [Task<Void, Never>] = []
    var boardStartTask: Task<Void, Never>?
    var openGaps: [BoardID: Int64] = [:]
    private var stopRequested = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastStartStamp: String?
    private let broadcaster = Broadcaster<SessionSnapshot>(replaysLatest: true)

    public init(environment: SessionEnvironment) {
        env = environment
        broadcaster.send(SessionSnapshot(state: .idle, session: nil, lastError: nil))
    }

    /// The current snapshot first, then every change.
    public nonisolated func updates() -> AsyncStream<SessionSnapshot> {
        broadcaster.stream()
    }

    public var snapshot: SessionSnapshot {
        SessionSnapshot(
            state: state, session: session, lastError: lastError, stopReason: stopReason,
            locationAuthorization: locationAuthorization, issue: issue
        )
    }

    /// The running session's counters, or the last session's final ones.
    public var counters: PipelineCounters? {
        get async {
            guard let pipeline else { return finalCounters }
            return await pipeline.counters
        }
    }

    public var currentLocation: LocationSample? {
        get async { await pipeline?.latestLocation }
    }

    public func destinationSnapshots() async -> [String: DestinationSnapshot] {
        var result: [String: DestinationSnapshot] = [:]
        for sink in sinks { result.merge(await sink.snapshots()) { $1 } }
        return result
    }

    // MARK: - Start and resume

    @discardableResult
    public func start() async throws -> SessionRow {
        guard state == .idle else { throw SessionError.notIdle }
        setState(.starting)
        let plan = SurveyPlan(settings: env.settings)
        var startedAt = env.now()
        // Two sessions in the same second would share a missionId and folder.
        if MissionID.timestamp(startedAt) == lastStartStamp {
            let fraction = startedAt.timeIntervalSince1970.truncatingRemainder(dividingBy: 1)
            try? await Task.sleep(for: .seconds(1 - fraction + 0.01))
            startedAt = env.now()
        }
        lastStartStamp = MissionID.timestamp(startedAt)
        let missionId = await env.isDemoSession()
            ? MissionID.makeDemo(startedAt: startedAt)
            : MissionID.make(installID: env.identity.installID, startedAt: startedAt)
        let row = SessionRow(
            id: UUID().uuidString,
            missionId: missionId,
            startedAt: startedAt, stoppedAt: nil, deviceSerialNumber: env.identity.deviceSerialNumber,
            deviceName: DeviceIdentity.name(settings: env.settings, installID: env.identity.installID), wifiAP: plan.wifiAP, wifiClient: plan.wifiClient, ble: plan.ble,
            rawFrames: plan.rawFrames, recordCount: 0, filteredCount: 0
        )
        try await run(row, plan: plan, numbers: RecordNumbers(), isNew: true)
        return row
    }

    /// Continues a session that was running when the app was terminated (for
    /// example relaunched by Bluetooth state restoration), keeping its missionId
    /// and continuing its record numbers. Boards need not be ready yet: the
    /// survey starts on them as soon as they are. The time the app was not
    /// running is recorded as an `appRelaunch` gap.
    public func resume(_ row: SessionRow) async throws {
        guard state == .idle else { throw SessionError.notIdle }
        setState(.starting)
        var plan = SurveyPlan(settings: env.settings)
        plan.wifiAP = row.wifiAP
        plan.wifiClient = row.wifiClient
        plan.ble = row.ble
        plan.rawFrames = row.rawFrames
        let numbers = (try? await env.store.recordNumbers(sessionID: row.id)) ?? RecordNumbers()
        try await run(row, plan: plan, numbers: numbers, isNew: false)
    }

    /// The newest session left running by a previous launch, if any (never the
    /// one running now). Older unfinished sessions are closed.
    public func unfinishedSession() async throws -> SessionRow? {
        let active = session?.id
        let rows = try await env.store.read { db in
            try SessionRow.filter(sql: "stoppedAt IS NULL").order(sql: "startedAt DESC").fetchAll(db)
        }.filter { $0.id != active }
        for older in rows.dropFirst() {
            try? await env.store.finishSession(older.id, stoppedAt: older.startedAt)
        }
        return rows.first
    }

    /// Marks a session left running by a previous launch as stopped.
    public func closeUnfinished(_ row: SessionRow) async throws {
        try await env.store.finishSession(row.id, stoppedAt: env.now())
    }

    private func run(_ row: SessionRow, plan: SurveyPlan, numbers: RecordNumbers, isNew: Bool) async throws {
        lastError = nil
        stopReason = nil
        issue = nil
        do {
            guard plan.surveysAnything else { throw SessionError.nothingToSurvey }
            let ready = await env.boards.readyBoards()
            if isNew {
                guard !ready.isEmpty else { throw SessionError.noBoardConnected }
                try await env.store.insertSession(row)
            } else {
                try await env.store.noteRelaunch(sessionID: row.id, at: env.now())
            }

            let context = SessionContext(
                sessionID: row.id, missionId: row.missionId, startedAt: row.startedAt,
                deviceSerialNumber: row.deviceSerialNumber, deviceName: row.deviceName, plan: plan, app: env.app,
                directory: SessionFiles.directory(root: env.filesRoot, startedAt: row.startedAt)
            )
            let sinks = await env.makeSinks(context)
            let pipeline = RecordPipeline(
                session: context, store: env.store, sinks: sinks, privacy: PrivacyFilter(settings: env.settings),
                policy: LocationSourcePolicy(preference: env.settings[Settings.locationSource]),
                battery: env.battery, numbers: numbers, now: env.now
            )
            for sink in sinks {
                // A destination that cannot start reports it in its status; the
                // survey itself still runs.
                await withTimeout(env.sinkTimeout) { try? await sink.start(context) }
            }
            self.session = row
            self.pipeline = pipeline
            finalCounters = nil
            self.sinks = sinks
            subscribe(pipeline, sessionID: row.id)
            await env.location.start(background: true)
            locationAuthorization = await env.location.authorization()
            if isNew {
                do {
                    try await env.boards.startSurvey(plan)
                } catch {
                    throw SessionError.boardStartFailed(String(describing: error))
                }
            } else {
                startBoardsWhenReady(plan)
            }
            startTimers(pipeline)
            setState(.running)
        } catch {
            let sessionError = error as? SessionError ?? .boardStartFailed(String(describing: error))
            await abortStart(row, isNew: isNew)
            lastError = sessionError
            setState(.idle)
            finishStopWaiters()
            throw sessionError
        }
        if stopRequested { await performStop(reason: .user) }
    }

    private func abortStart(_ row: SessionRow, isNew: Bool) async {
        cancelTasks()
        for sink in sinks {
            await withTimeout(env.sinkTimeout) { await sink.stop() }
        }
        sinks = []
        if pipeline != nil { await env.location.stop() }
        pipeline = nil
        session = nil
        stopRequested = false
        if isNew { try? await env.store.deleteSession(row.id) }
        await env.boards.stopSurvey()
    }

    // MARK: - Stop

    /// Stops the survey. A Stop while starting takes effect as soon as the
    /// start finishes; a Stop while stopping waits for that stop. Returns when
    /// the controller is idle.
    public func stop() async {
        await stop(reason: .user)
    }

    func stop(reason: StopReason) async {
        switch state {
        case .idle:
            return
        case .running:
            await performStop(reason: reason)
        case .starting, .stopping:
            if state == .starting { stopRequested = true }
            await withCheckedContinuation { stopWaiters.append($0) }
        }
    }

    private func performStop(reason: StopReason) async {
        guard state == .running, let session, let pipeline else { return }
        stopRequested = false
        stopReason = reason
        setState(.stopping)
        boardStartTask?.cancel()
        boardStartTask = nil
        await withTimeout(env.sinkTimeout) { [boards = env.boards] in await boards.stopSurvey() }
        try? await Task.sleep(for: env.stopGrace)
        let running = tasks
        cancelTasks()
        // Let in-flight gap writes land before the session is closed.
        await withTimeout(.seconds(2)) {
            for task in running { await task.value }
        }
        await withTimeout(env.sinkTimeout) { await pipeline.flush() }
        finalCounters = await pipeline.counters
        let stoppedAt = env.now()
        if (try? await env.store.finishSession(session.id, stoppedAt: stoppedAt)) == nil {
            do {
                try await env.store.finishSession(session.id, stoppedAt: stoppedAt)
            } catch {
                issue = "The end of the session could not be saved: \(error.localizedDescription)"
            }
        }
        for sink in sinks {
            await withTimeout(env.sinkTimeout) { await sink.stop() }
        }
        await env.location.stop()
        self.pipeline = nil
        openGaps = [:]
        self.session?.stoppedAt = stoppedAt
        setState(.idle)
        finishStopWaiters()
    }

    private func finishStopWaiters() {
        let waiters = stopWaiters
        stopWaiters = []
        waiters.forEach { $0.resume() }
    }

    func cancelTasks() {
        tasks.forEach { $0.cancel() }
        tasks = []
        boardStartTask?.cancel()
        boardStartTask = nil
    }

    func setState(_ newState: SessionState) {
        state = newState
        broadcaster.send(snapshot)
    }
}
