import BoardProtocol
import Foundation
import os

/// `BoardTransport` for real boards over Bluetooth LE.
///
/// All CoreBluetooth access goes through a `BLECentral`, so this type holds the
/// whole board logic (connection setup, pairing errors, request/response
/// correlation, framing, OTA flow control) and runs in tests against
/// `SimulatedBLECentral`.
///
/// Only boards in the `KnownBoardStore` are connected without a user action
/// (state restoration and system reconnects); any other board the system
/// reports as connected is dropped.
public actor BLEBoardTransport: BoardTransport {
    public struct Timing: Sendable {
        public var connect: Duration
        /// Service discovery, Info read and subscriptions after pairing.
        public var gattStep: Duration
        /// The first encrypted access, which waits for the user to accept pairing.
        public var pairing: Duration
        /// Longest wait for write-without-response flow control.
        public var writeReady: Duration
        /// A board not heard for this long leaves the discovered list.
        public var discoveryExpiry: Duration

        public init(
            connect: Duration = .seconds(15), gattStep: Duration = .seconds(10), pairing: Duration = .seconds(60),
            writeReady: Duration = .seconds(5), discoveryExpiry: Duration = .seconds(10)
        ) {
            self.connect = connect
            self.gattStep = gattStep
            self.pairing = pairing
            self.writeReady = writeReady
            self.discoveryExpiry = discoveryExpiry
        }

        public static let standard = Timing()
    }

    struct Link {
        var state: BoardConnectionState = .disconnected(nil)
        var info: NSBBoardInfo?
        var decoder = BoardNotificationDecoder()
        var disconnectRequested = false
        var setupRunning = false
        var controlBusy = false
        var controlQueue: [CheckedContinuation<Void, Never>] = []
        var pendingRequestID: UInt32?
    }

    enum WaitKey: Hashable {
        case connect(UUID), gatt(UUID), read(UUID, BoardCharacteristic), notify(UUID, BoardCharacteristic)
        case control(UUID), writeReady(UUID)

        var peripheral: UUID {
            switch self {
            case .connect(let id), .gatt(let id), .read(let id, _), .notify(let id, _), .control(let id), .writeReady(let id): id
            }
        }
    }

    enum WaitValue: Sendable {
        case none
        case data(Data)
        case response(NSBControlResponse)
    }

    struct Waiter {
        let token: UInt64
        let continuation: CheckedContinuation<Result<WaitValue, BoardTransportError>, Never>
        var timeoutTask: Task<Void, Never>?
    }

    static let log = Logger(subsystem: "app.networksurvey.BoardKit", category: "ble")

    public nonisolated let central: any BLECentral
    nonisolated let store: any KnownBoardStore
    nonisolated let timing: Timing
    nonisolated let discoveryBroadcaster = Broadcaster<[DiscoveredBoard]>(replaysLatest: true)
    nonisolated let eventBroadcaster = Broadcaster<BoardEvent>()
    /// Keyed by CoreBluetooth peripheral identifier, the connection key. Board
    /// IDs are mapped at the API boundary (`peripheral(for:)`, `publicID(_:)`).
    var links: [UUID: Link] = [:]
    var known: [UUID: KnownBoard]
    /// Stable IDs learned from Info (and from known boards), both directions.
    var stableIDs: [UUID: BoardID] = [:]
    var peripheralsByID: [BoardID: UUID] = [:]
    var seen: [UUID: DiscoveredBoard] = [:]
    /// Whether the board advertised a bond just before the current link came up,
    /// kept until setup finishes, to explain an encryption failure during it.
    var hadBondBeforeLink: [UUID: Bool] = [:]
    var waiters: [WaitKey: Waiter] = [:]
    var nextToken: UInt64 = 0
    var scanning = false
    var lastPublish = Date.distantPast
    var pruneTask: Task<Void, Never>?
    var deferredRestore: [BLERestoredPeripheral]?

    public init(central: any BLECentral, store: any KnownBoardStore = InMemoryKnownBoardStore(), timing: Timing = .standard) {
        self.central = central
        self.store = store
        self.timing = timing
        let stored = store.load().compactMap { board in board.connectionKey.map { ($0, board) } }
        known = Dictionary(stored, uniquingKeysWith: { $1 })
        for (peripheral, board) in known where board.id.isStable {
            stableIDs[peripheral] = board.id
            peripheralsByID[board.id] = peripheral
        }
        let events = central.events()
        Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    #if canImport(CoreBluetooth)
    /// A transport on CoreBluetooth. On iOS pass a restore identifier so the
    /// system can relaunch the app for board events (create it at launch).
    public static func coreBluetooth(
        restoreIdentifier: String? = nil, store: any KnownBoardStore = UserDefaultsKnownBoardStore()
    ) -> BLEBoardTransport {
        BLEBoardTransport(central: CoreBluetoothCentral(restoreIdentifier: restoreIdentifier), store: store)
    }
    #endif

    // MARK: - BoardTransport

    public nonisolated func discoveries() -> AsyncStream<[DiscoveredBoard]> {
        discoveryBroadcaster.stream()
    }

    public nonisolated func events() -> AsyncStream<BoardEvent> {
        eventBroadcaster.stream()
    }

    public func startScanning() async {
        scanning = true
        if central.powerState == .poweredOn { central.startScan() }
        pruneTask?.cancel()
        pruneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.pruneDiscoveries()
            }
        }
        publishDiscoveries()
    }

    public func stopScanning() async {
        scanning = false
        central.stopScan()
        pruneTask?.cancel()
        pruneTask = nil
    }

    public func connect(_ board: BoardID, timeout: Duration?) async throws(BoardTransportError) {
        guard let id = peripheral(for: board) else { throw .unknownBoard }
        try requirePoweredOn()
        if links[id]?.state.isConnected == true { return }
        guard links[id]?.setupRunning != true else { throw .connectionFailed("a connect is already in progress") }
        guard seen[id] != nil || central.knownPeripherals([id]).contains(id) else { throw .unknownBoard }
        links[id, default: Link()].disconnectRequested = false
        links[id]?.setupRunning = true
        defer { links[id]?.setupRunning = false }
        setState(.connecting, for: id)
        let result = await wait(.connect(id), timeout: timeout) { central.connect(id) }
        if case .failure(let error) = result {
            central.cancelConnection(id)
            markDisconnected(id, reason: Self.reason(for: error))
            throw error
        }
        try await setUp(id)
    }

    public func disconnect(_ board: BoardID) async {
        guard let id = peripheral(for: board), links[id] != nil else { return }
        links[id]?.disconnectRequested = true
        central.cancelConnection(id)
        failWaiters(for: id, with: .cancelled)
        markDisconnected(id, reason: .requested)
    }

    public func readInfo(_ board: BoardID) async throws(BoardTransportError) -> NSBBoardInfo {
        guard let id = peripheral(for: board) else { throw .unknownBoard }
        if let link = links[id], link.state.isConnected, let info = link.info { return info }
        try requirePoweredOn()
        guard links[id]?.setupRunning != true, links[id]?.state.isDisconnected ?? true else {
            throw .connectionFailed("a connect is already in progress")
        }
        guard seen[id] != nil || central.knownPeripherals([id]).contains(id) else { throw .unknownBoard }
        links[id, default: Link()].setupRunning = true
        links[id]?.disconnectRequested = true  // The link is closed again right after the read.
        defer {
            links[id]?.setupRunning = false
            central.cancelConnection(id)
        }
        _ = try await step(.connect(id), timeout: timing.connect) { central.connect(id) }
        _ = try await step(.gatt(id), timeout: timing.gattStep) { central.discoverGATT(id) }
        guard case .data(let bytes) = try await step(.read(id, .info), timeout: timing.gattStep, { central.read(.info, on: id) }),
              let info = try? NSBBoardInfo(serializedBytes: bytes)
        else { throw .malformedResponse }
        learn(info, for: id)
        return info
    }

    public func send(
        _ request: NSBControlRequest, to board: BoardID, timeout: Duration
    ) async throws(BoardTransportError) -> NSBControlResponse {
        guard let id = peripheral(for: board), links[id]?.state.isConnected == true else { throw .notConnected }
        let data: Data
        do {
            data = try request.serializedData()
        } catch {
            throw .invalidRequest("\(error)")
        }
        guard data.count <= BoardLimits.controlRequestBytes else {
            throw .invalidRequest("request is \(data.count) bytes, the limit is \(BoardLimits.controlRequestBytes)")
        }
        await acquireControl(id)
        defer { releaseControl(id) }
        guard links[id]?.state.isConnected == true else { throw .notConnected }
        links[id]?.pendingRequestID = request.requestID
        // The ATT write response only confirms delivery; the result is the indication.
        let result = await wait(.control(id), timeout: timeout) {
            central.write(data, to: .control, on: id, withResponse: true)
        }
        links[id]?.pendingRequestID = nil
        guard case .response(let response) = try result.get() else { throw .malformedResponse }
        return response
    }

    public func maximumOTAWriteLength(for board: BoardID) async -> Int? {
        guard let id = peripheral(for: board), links[id]?.state.isConnected == true else { return nil }
        return central.maximumWriteLength(id, withResponse: false)
    }

    public func writeOTAChunk(_ chunk: Data, to board: BoardID) async throws(BoardTransportError) {
        guard let id = peripheral(for: board), links[id]?.state.isConnected == true else { throw .notConnected }
        let limit = central.maximumWriteLength(id, withResponse: false)
        guard chunk.count <= limit else { throw .invalidRequest("chunk of \(chunk.count) bytes, the limit is \(limit)") }
        // Writing while the stack has no room makes delivery best effort, so wait.
        let deadline = ContinuousClock.now + timing.writeReady
        while !central.canSendWriteWithoutResponse(id) {
            guard ContinuousClock.now < deadline else { throw .timeout }
            let result = await wait(.writeReady(id), timeout: .milliseconds(250)) {}
            if case .failure(let error) = result, error != .timeout { throw error }
            guard links[id]?.state.isConnected == true else { throw .notConnected }
        }
        central.write(chunk, to: .ota, on: id, withResponse: false)
    }

    public func connectionStates() async -> [BoardID: BoardConnectionState] {
        Dictionary(links.map { (publicID($0.key), $0.value.state) }, uniquingKeysWith: { $1 })
    }

    public func knownBoards() async -> [KnownBoard] {
        known.values.filter { !$0.isRemoved }.sorted { $0.lastConnected > $1.lastConnected }
    }

    public func forgetKnownBoard(_ board: BoardID, keepBond: Bool) async {
        let id = peripheral(for: board)
        if keepBond {
            let now = Date()
            if let id { known[id]?.removedAt = now }
            store.markRemoved(board, connectionKey: id, at: now)
        } else {
            if let id { known[id] = nil }
            // The board may be stored under its stable ID while `board` is provisional.
            store.save(store.load().filter { $0.id != board && (id == nil || $0.connectionKey != id) })
        }
        if scanning { publishDiscoveries() }
    }

    /// CBError 15 (encryption timed out) on a board this phone has a bond with,
    /// while the board advertises that it has none, means the board lost that
    /// bond, the same as CBError 14. Otherwise it may be a weak link.
    func linkError(_ error: BLEError, on id: UUID) -> BoardTransportError {
        let advertisedBond = seen[id]?.hasBond ?? hadBondBeforeLink[id]
        if error.kind == .encryptionTimedOut, known[id] != nil, advertisedBond == false { return .bondMissing }
        return error.transportError
    }

    // MARK: - Board IDs

    /// The peripheral behind a board ID: a provisional ID is the peripheral
    /// UUID itself, a stable one must have been learned from Info or a known board.
    func peripheral(for board: BoardID) -> UUID? {
        board.peripheralUUID ?? peripheralsByID[board]
    }

    /// The ID events carry: stable once the board's address is known.
    func publicID(_ peripheral: UUID) -> BoardID {
        stableIDs[peripheral] ?? known[peripheral]?.id ?? BoardID(peripheral)
    }

    func learn(_ info: NSBBoardInfo, for peripheral: UUID) {
        guard let stable = BoardID(info: info) else { return }
        stableIDs[peripheral] = stable
        peripheralsByID[stable] = peripheral
    }

    // MARK: - Connection setup

    /// Discovers GATT, reads Info, then subscribes. The Control subscription is
    /// the first encrypted access, which makes the system pair a new board.
    func setUp(_ id: UUID) async throws(BoardTransportError) {
        do throws(BoardTransportError) {
            _ = try await step(.gatt(id), timeout: timing.gattStep) { central.discoverGATT(id) }
            guard case .data(let bytes) = try await step(.read(id, .info), timeout: timing.gattStep, { central.read(.info, on: id) }),
                  let info = try? NSBBoardInfo(serializedBytes: bytes)
            else { throw .malformedResponse }
            links[id]?.info = info
            learn(info, for: id)
            links[id]?.decoder.reset()
            try await subscribe(.control, on: id, timeout: timing.pairing)
            for characteristic in [BoardCharacteristic.status, .records, .ota] {
                try await subscribe(characteristic, on: id, timeout: timing.gattStep)
            }
            // Raw is optional (third-party boards may leave it out).
            try? await subscribe(.raw, on: id, timeout: timing.gattStep)
            guard links[id]?.state.isDisconnected == false else { throw .notConnected }
            let record = KnownBoard(info: info, peripheralID: id, at: Date())
            known[id] = record
            store.upsert(record)
            Self.log.info("board \(info.shortID, privacy: .public) ready, max write \(self.central.maximumWriteLength(id, withResponse: false))")
            hadBondBeforeLink[id] = nil
            setState(.connected(info), for: id)
        } catch {
            // A characteristic missing from GATT is a broken board, not an unknown one.
            let error: BoardTransportError = error == .unknownBoard ? .connectionFailed("board characteristics missing") : error
            central.cancelConnection(id)
            markDisconnected(id, reason: Self.reason(for: error))
            throw error
        }
    }

    private func subscribe(_ characteristic: BoardCharacteristic, on id: UUID, timeout: Duration) async throws(BoardTransportError) {
        _ = try await step(.notify(id, characteristic), timeout: timeout) {
            central.setNotify(true, for: characteristic, on: id)
        }
    }

    /// A known board connected without a request from us (state restoration or
    /// a restored pending connect): set it up so the manager can resume.
    func adopt(_ id: UUID) {
        guard links[id]?.setupRunning != true else { return }
        links[id, default: Link()].setupRunning = true
        links[id]?.disconnectRequested = false
        setState(.connecting, for: id)
        Task {
            try? await self.setUp(id)
            self.finishAdopt(id)
        }
    }

    private func finishAdopt(_ id: UUID) {
        links[id]?.setupRunning = false
    }

    private func requirePoweredOn() throws(BoardTransportError) {
        let state = central.powerState
        guard state == .poweredOn else { throw .bluetoothUnavailable(state.rawValue) }
    }

    static func reason(for error: BoardTransportError) -> BoardDisconnectReason {
        switch error {
        case .bondMissing: .bondMissing
        case .pairingRejected: .pairingRejected
        case .cancelled: .requested
        default: .failed(String(describing: error))
        }
    }

    // MARK: - Control serialization

    private func acquireControl(_ id: UUID) async {
        guard links[id]?.controlBusy == true else {
            links[id]?.controlBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            links[id]?.controlQueue.append(continuation)
        }
    }

    private func releaseControl(_ id: UUID) {
        guard var link = links[id] else { return }
        if link.controlQueue.isEmpty {
            link.controlBusy = false
            links[id] = link
        } else {
            let next = link.controlQueue.removeFirst()
            links[id] = link
            next.resume()  // Ownership passes to the next sender.
        }
    }
}
