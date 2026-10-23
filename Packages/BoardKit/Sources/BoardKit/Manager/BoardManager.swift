import BoardProtocol
import Foundation
import Observation
import Synchronization

/// Owns a `BoardTransport` and up to four boards: discovery, connect with
/// Hello and SetTime, reconnects with backoff, the channel split across boards
/// (see `ChannelPlanner`), per-board status, counters and drop accounting, and
/// one merged record stream for SurveyCore.
///
/// Records do not pass through the main actor: `records()`, `rawFrames()` and
/// `recordBatches()` are fed straight from the transport. Observable state
/// (`boards`, `discovered`) is updated on the main actor; counters refresh with
/// each status message.
@MainActor
@Observable
public final class BoardManager {
    public static let maxBoards = 4

    public struct BoardState: Sendable {
        public var connection: BoardConnectionState = .disconnected(nil)
        public var info: NSBBoardInfo?
        public var status: NSBBoardStatus?
        public var configured: NSBConfigureResult?
        public var assignment: BoardAssignment?
        public var compatibility: BoardCompatibility = .unknown
        public var issue: BoardIssue?
        public var reconnect: ReconnectState?
        public var counters = BoardCounters()
        /// Connected, Hello and SetTime done.
        public var isReady = false
        /// The last Hello answer (firmware version, `otaImageConfirmed`).
        public var hello: NSBHelloResult?
        /// A firmware update owns the board; the manager leaves it alone.
        public var isUpdating = false

        public var recordCount: Int { counters.records }
        public var missedNotifications: Int { counters.missedNotifications }
    }

    public let transport: any BoardTransport
    public let appVersion: String
    public let reconnectPolicy: ReconnectPolicy
    /// How long a dropped board keeps its channels before the others take them over.
    public let resplitGrace: Duration
    public private(set) var discovered: [DiscoveredBoard] = []
    public internal(set) var boards: [BoardID: BoardState] = [:]
    /// The running survey's capture settings, nil when no survey runs.
    public internal(set) var capture: SurveyCapture?
    public internal(set) var roles: [BoardID: BoardRolePreference] = [:]
    /// Phone Bluetooth state as the transport last reported it.
    public private(set) var bluetoothState: BLEPowerState = .unknown

    nonisolated let router = BoardRecordRouter()
    nonisolated let eventOut = Broadcaster<BoardManagerEvent>()
    /// Boards the user wants connected; only these are reconnected.
    @ObservationIgnored var wanted: Set<BoardID> = []
    /// Boards with a manager connect or handshake in progress.
    @ObservationIgnored var busy: Set<BoardID> = []
    /// Busy boards whose link dropped meanwhile; reconnected once the work ends.
    @ObservationIgnored var droppedWhileBusy: Set<BoardID> = []
    /// Provisional IDs already resolved to stable ones, for events that lag.
    @ObservationIgnored var stableAliases: [BoardID: BoardID] = [:]
    /// Counts deliberate disconnects per board, so a pending adoption that
    /// raced one can tell and stand down.
    @ObservationIgnored var releases: [BoardID: Int] = [:]
    /// Boards a firmware update drives directly over the transport.
    @ObservationIgnored var updating: Set<BoardID> = []
    @ObservationIgnored var reconnectTasks: [BoardID: Task<Void, Never>] = [:]
    @ObservationIgnored var gapStarts: [BoardID: Date] = [:]
    @ObservationIgnored var resplitTask: Task<Void, Never>?
    @ObservationIgnored var rebalancing = false
    @ObservationIgnored var rebalanceQueue: [CheckedContinuation<Void, Never>] = []
    /// Event pumps, ended in deinit (the transport's streams outlive the manager).
    private nonisolated let listeners = Mutex<[Task<Void, Never>]>([])
    @ObservationIgnored private var nextRequestID: UInt32 = 1

    public init(
        transport: any BoardTransport, appVersion: String? = nil, reconnectPolicy: ReconnectPolicy = .standard,
        resplitGrace: Duration = .seconds(10)
    ) {
        self.transport = transport
        self.appVersion = appVersion ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        self.reconnectPolicy = reconnectPolicy
        self.resplitGrace = resplitGrace
        let discoveries = transport.discoveries()
        let events = transport.events()
        let discoveryPump = Task { [weak self] in
            for await list in discoveries {
                self?.discovered = list
                self?.noteResetBoards(in: list)
            }
        }
        let eventPump = Task.detached { [weak self, router] in
            for await event in events {
                switch event {
                case .records(let id, let received): router.route(id, received)
                case .rawFrames(let id, let frames): router.route(id, frames)
                case .otaAck: break  // OtaChunkSender listens to the transport directly.
                default: await self?.handle(event)
                }
            }
        }
        // Boards that connected before this manager subscribed (state restoration).
        let catchUp = Task { [weak self, transport] in
            for (id, state) in await transport.connectionStates() where state.isConnected {
                guard let self, self.boards[id]?.connection.isConnected != true else { continue }
                self.handle(.connectionState(id, state))
            }
        }
        listeners.withLock { $0 = [discoveryPump, eventPump, catchUp] }
    }

    deinit {
        listeners.withLock { $0.forEach { $0.cancel() } }
    }

    // MARK: - Streams

    /// Every record from every board, as it arrives. Each call is a new subscriber.
    public nonisolated func records() -> AsyncStream<BoardRecordEnvelope> {
        router.records.stream()
    }

    public nonisolated func rawFrames() -> AsyncStream<BoardRawFrameEnvelope> {
        router.rawFrames.stream()
    }

    /// Record batches with their framing details (sequence, gaps).
    public nonisolated func recordBatches() -> AsyncStream<(BoardID, ReceivedRecordBatch)> {
        router.batches.stream()
    }

    public nonisolated func events() -> AsyncStream<BoardManagerEvent> {
        eventOut.stream()
    }

    /// Up-to-date counters for the current survey (the copy in `boards`
    /// refreshes with status).
    public nonisolated func counters(for id: BoardID) -> BoardCounters {
        router.counters(id)
    }

    public var readyBoards: [BoardID] {
        boards.filter(\.value.isReady).keys.sorted { order($0) < order($1) }
    }

    // MARK: - Discovery and connection

    public func startScanning() async {
        await transport.startScanning()
    }

    public func stopScanning() async {
        await transport.stopScanning()
    }

    public func knownBoards() async -> [KnownBoard] {
        await transport.knownBoards()
    }

    /// Connects (pairing on first use), then Hello and SetTime. An incompatible
    /// board stays connected, so its firmware can be updated, but is not ready
    /// and throws `BoardManagerError.incompatible` with a reason to show.
    /// A failed first connect is not retried and leaves the board disconnected,
    /// so it advertises again.
    ///
    /// Returns the board's stable ID: a board seen only in a scan has a
    /// provisional ID until its Info is read; from then on `boards`, events and
    /// records use the stable one.
    @discardableResult
    public func connect(_ board: BoardID) async throws -> BoardID {
        var id = stableAliases[board] ?? board
        if boards[id]?.isReady == true { return id }
        let inUse = wanted.union(boards.filter { $0.value.connection.isConnected }.keys)
        guard inUse.contains(id) || inUse.count < Self.maxBoards else { throw BoardManagerError.tooManyBoards }
        guard !busy.contains(id), !updating.contains(id) else { throw BoardManagerError.busy }
        beginBusy(id)
        wanted.insert(id)
        boards[id, default: BoardState()].issue = nil
        do {
            try await transport.connect(id)
            id = await resolveStableID(id)
            try await handshake(id)
        } catch {
            busy.remove(id)
            droppedWhileBusy.remove(id)
            if case BoardManagerError.incompatible = error { throw error }  // Kept connected for an update.
            wanted.remove(id)
            releases[id, default: 0] += 1
            if let error = error as? BoardTransportError { note(error, for: id) }
            await transport.disconnect(id)
            throw error
        }
        await rebalance(force: [id])
        endBusy(id)
        return id
    }

    /// Moves a board from its provisional ID to its stable one, once the
    /// transport has read Info. Returns the ID to use from now on.
    func resolveStableID(_ id: BoardID) async -> BoardID {
        guard !id.isStable, let info = try? await transport.readInfo(id), let stable = BoardID(info: info), stable != id else {
            return id
        }
        stableAliases[id] = stable
        if let state = boards.removeValue(forKey: id) {
            var merged = boards[stable] ?? state
            merged.issue = state.issue ?? merged.issue
            merged.info = info
            boards[stable] = merged
        }
        for set in [\BoardManager.wanted, \BoardManager.busy, \BoardManager.droppedWhileBusy] where self[keyPath: set].remove(id) != nil {
            self[keyPath: set].insert(stable)
        }
        if let role = roles.removeValue(forKey: id) { roles[stable] = role }
        return stable
    }

    func beginBusy(_ id: BoardID) {
        busy.insert(id)
        droppedWhileBusy.remove(id)
    }

    /// Ends a busy period. A link loss reported meanwhile was skipped by the
    /// event handler, so the reconnect starts now.
    func endBusy(_ id: BoardID) {
        busy.remove(id)
        guard droppedWhileBusy.remove(id) != nil, wanted.contains(id), reconnectTasks[id] == nil else { return }
        beginGap(id)
        startReconnect(id)
    }

    /// Connects every known board silently (pending connects), for app launch.
    /// Unknown boards are never connected this way.
    public func reconnectKnownBoards() async {
        for board in await transport.knownBoards().prefix(Self.maxBoards) where !wanted.contains(board.id) && !updating.contains(board.id) {
            wanted.insert(board.id)
            if boards[board.id]?.connection.isConnected == true {
                if boards[board.id]?.isReady != true { startReconnect(board.id) }
            } else {
                startReconnect(board.id)
            }
        }
    }

    public func disconnect(_ id: BoardID) async {
        stopWanting(id)
        releases[id, default: 0] += 1
        boards[id]?.isReady = false
        await transport.disconnect(id)
        await rebalance()
    }

    /// Disconnects the board and stops using it. By default both sides keep the
    /// bond, so the board can be added back without pairing (and without a trip
    /// to Settings > Bluetooth). `wipeBonds` also tells a connected board to
    /// delete its bonds (ForgetBonds); the phone keeps its half regardless, so
    /// the user must then choose Forget This Device in Settings > Bluetooth
    /// before pairing again. Returns whether the board confirmed the wipe (true
    /// when no wipe was asked for); an unconfirmed wipe leaves the board in use.
    @discardableResult
    public func forget(_ id: BoardID, wipeBonds: Bool = false) async -> Bool {
        stopWanting(id)
        releases[id, default: 0] += 1
        // ForgetBonds works before Hello; the transport fails fast when not connected.
        let confirmed = wipeBonds ? (try? await send(.forgetBonds(NSBForgetBonds()), to: id))?.result == .ok : true
        if !confirmed {
            // The board may still hold its bonds: keep using it, so the user can try again.
            wanted.insert(id)
            return false
        }
        await transport.disconnect(id)
        await transport.forgetKnownBoard(id, keepBond: !wipeBonds)
        boards[id] = nil
        roles[id] = nil
        router.reset(id)
        await rebalance()
        return confirmed
    }

    // MARK: - Commands

    @discardableResult
    public func configure(_ id: BoardID, _ configure: NSBConfigure) async throws -> NSBConfigureResult {
        let response = try await send(.configure(configure), to: id)
        try expectOK(response)
        guard case .configure(let result)? = response.payload else { throw BoardTransportError.malformedResponse }
        boards[id, default: BoardState()].configured = result
        return result
    }

    public func start(_ id: BoardID) async throws {
        try await expectOK(send(.start(NSBStart()), to: id))
    }

    public func stop(_ id: BoardID) async throws {
        try await expectOK(send(.stop(NSBStop()), to: id))
    }

    public func send(_ command: NSBControlRequest.OneOf_Command, to id: BoardID) async throws -> NSBControlResponse {
        var request = NSBControlRequest()
        request.requestID = nextRequestID
        nextRequestID = nextRequestID == .max ? 1 : nextRequestID + 1
        request.command = command
        return try await transport.send(request, to: id)
    }

    func expectOK(_ response: NSBControlResponse) throws {
        guard response.result == .ok else { throw BoardManagerError.rejected(response.result, response.message) }
    }

    // MARK: - Transport events

    func handle(_ event: BoardEvent) {
        switch event {
        case .connectionState(let id, let state):
            // A provisional ID's late events belong to the board's stable entry.
            handleConnection(stableAliases[id] ?? id, state)
        case .status(let id, let status):
            boards[id, default: BoardState()].status = status
            let (counters, drops) = router.apply(status, from: id)
            boards[id]?.counters = counters
            eventOut.send(.status(id, status))
            if !drops.isEmpty { eventOut.send(.drops(id, drops)) }
        case .bluetooth(let state):
            bluetoothState = state
        case .records, .rawFrames, .otaAck:
            break
        }
    }

    /// Stable board order for planning: short ID, then identifier.
    func order(_ id: BoardID) -> String {
        (boards[id]?.info?.shortID ?? "") + id.description
    }
}
