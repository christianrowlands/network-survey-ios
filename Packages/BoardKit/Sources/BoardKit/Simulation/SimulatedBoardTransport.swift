import BoardProtocol
import Foundation
import SwiftProtobuf

/// A `BoardTransport` backed by simulated boards that share one synthetic radio
/// neighbourhood. Used for the demo board, previews, UI tests and unit tests.
///
/// Records go through the same framing and sequence-gap decoding as real
/// hardware. Test hooks inject lost notifications and dropped links.
///
/// With `.manual` time only moves when `advance(byMs:)` is called, which makes
/// runs deterministic for a given seed. `.realtime` runs on a background task.
public actor SimulatedBoardTransport: BoardTransport {
    public enum TimeSource: Sendable, Equatable {
        case realtime(speed: Double)
        case manual
    }

    /// Records a disconnected board can hold before it starts dropping.
    public static let ringCapacity = 4000
    static let tickMs: UInt64 = 100

    private struct Board {
        var engine: SimulatedBoardEngine
        var state: BoardConnectionState = .disconnected(nil)
        var recordSequence: UInt16 = 0
        var statusSequence: UInt16 = 0
        var rawSequence: UInt16 = 0
        var decoder = BoardNotificationDecoder()
        var notificationsToLose = 0
        var ring: [NSBRecordBatch] = []
        var ringRecords = 0
    }

    public nonisolated let profiles: [SimulatedBoardProfile]
    public nonisolated let world: SimulatedWorld
    private let timeSource: TimeSource
    private let startDate: Date
    private let discoveryBroadcaster = Broadcaster<[DiscoveredBoard]>(replaysLatest: true)
    private let eventBroadcaster = Broadcaster<BoardEvent>()
    private var boards: [BoardID: Board] = [:]
    private var known: [BoardID: KnownBoard] = [:]
    private var simTimeMs: UInt64 = 0
    private var scanning = false
    private var rng: SeededGenerator
    private var clockTask: Task<Void, Never>?

    public init(
        boardCount: Int = 1, seed: UInt64 = 1, timeSource: TimeSource = .realtime(speed: 1),
        startDate: Date = Date()
    ) {
        self.init(
            profiles: SimulatedBoardProfile.standard(count: boardCount, seed: seed),
            world: SimulatedWorld(seed: seed), seed: seed, timeSource: timeSource, startDate: startDate
        )
    }

    public init(
        profiles: [SimulatedBoardProfile], world: SimulatedWorld, seed: UInt64,
        timeSource: TimeSource = .realtime(speed: 1), startDate: Date = Date()
    ) {
        self.profiles = profiles
        self.world = world
        self.timeSource = timeSource
        self.startDate = startDate
        rng = SeededGenerator(seed: seed).derived(7)
        for profile in profiles {
            boards[profile.id] = Board(engine: SimulatedBoardEngine(profile: profile, world: world, seed: seed))
        }
    }

    // MARK: - BoardTransport

    public nonisolated func discoveries() -> AsyncStream<[DiscoveredBoard]> {
        discoveryBroadcaster.stream()
    }

    public nonisolated func events() -> AsyncStream<BoardEvent> {
        eventBroadcaster.stream()
    }

    public func startScanning() async {
        scanning = true
        startClockIfNeeded()
        publishDiscoveries()
    }

    public func stopScanning() async {
        scanning = false
    }

    public func connect(_ id: BoardID, timeout: Duration?) async throws(BoardTransportError) {
        guard let board = boards[id] else { throw .unknownBoard }
        guard !board.state.isConnected else { return }
        startClockIfNeeded()
        setState(.connecting, for: id)
        await realtimeDelay(ms: 300)
        guard boards[id]?.state == .connecting else { throw .connectionFailed("cancelled") }
        boards[id]?.recordSequence = 0
        boards[id]?.statusSequence = 0
        boards[id]?.rawSequence = 0
        boards[id]?.decoder.reset()
        setState(.connected(board.engine.profile.boardInfo), for: id)
        known[id] = KnownBoard(id: id, info: board.engine.profile.boardInfo, at: now)
        flushRing(id)
        if scanning { publishDiscoveries() }
    }

    public func disconnect(_ id: BoardID) async {
        dropLink(id, reason: .requested)
    }

    public func readInfo(_ id: BoardID) async throws(BoardTransportError) -> NSBBoardInfo {
        guard let board = boards[id] else { throw .unknownBoard }
        return board.engine.profile.boardInfo
    }

    public func send(
        _ request: NSBControlRequest, to id: BoardID, timeout: Duration
    ) async throws(BoardTransportError) -> NSBControlResponse {
        guard boards[id] != nil else { throw .unknownBoard }
        guard boards[id]?.state.isConnected == true else { throw .notConnected }
        await realtimeDelay(ms: 20)
        guard let response = boards[id]?.engine.handle(request) else { throw .notConnected }
        return response
    }

    public func maximumOTAWriteLength(for id: BoardID) async -> Int? {
        guard let board = boards[id], board.state.isConnected else { return nil }
        return Int(board.engine.profile.mtu) - 3
    }

    /// Simulated boards have no OTA; `SimulatedBLECentral` does.
    public func writeOTAChunk(_ chunk: Data, to id: BoardID) async throws(BoardTransportError) {
        throw .unsupported
    }

    public func connectionStates() async -> [BoardID: BoardConnectionState] {
        boards.mapValues(\.state)
    }

    public func knownBoards() async -> [KnownBoard] {
        known.values.filter { !$0.isRemoved }.sorted { $0.lastConnected > $1.lastConnected }
    }

    public func forgetKnownBoard(_ id: BoardID, keepBond: Bool) async {
        if keepBond { known[id]?.removedAt = Date() } else { known[id] = nil }
    }

    // MARK: - Test hooks and time

    /// Loses the next `count` Records notifications of a board, so the receiver sees a sequence gap.
    public func injectLostNotifications(_ count: Int, on id: BoardID) {
        boards[id]?.notificationsToLose += count
    }

    /// Drops the link as if the board went out of range. The board keeps surveying
    /// and buffers records until the phone reconnects.
    public func injectDisconnect(_ id: BoardID, reason: BoardDisconnectReason = .linkLost) {
        dropLink(id, reason: reason)
    }

    /// Moves simulated time forward (manual time source; also usable in realtime).
    public func advance(byMs ms: UInt64) {
        var remaining = ms
        while remaining > 0 {
            let step = min(remaining, Self.tickMs)
            remaining -= step
            simTimeMs += step
            for id in profiles.map(\.id) {
                guard let outputs = boards[id]?.engine.advance(byMs: step) else { continue }
                for output in outputs { deliver(output, from: id) }
            }
            if scanning, simTimeMs % 1000 < step { publishDiscoveries() }
        }
    }

    /// Stops the clock and ends every stream.
    public func shutdown() {
        clockTask?.cancel()
        clockTask = nil
        discoveryBroadcaster.finish()
        eventBroadcaster.finish()
    }

    // MARK: - Internals

    private var now: Date { startDate.addingTimeInterval(Double(simTimeMs) / 1000) }

    private func startClockIfNeeded() {
        guard case .realtime(let speed) = timeSource, clockTask == nil else { return }
        let interval = Duration.milliseconds(Double(Self.tickMs) / max(speed, 0.01))
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.advance(byMs: Self.tickMs)
            }
        }
    }

    private func realtimeDelay(ms: Double) async {
        guard case .realtime(let speed) = timeSource else { return }
        try? await Task.sleep(for: .milliseconds(ms / max(speed, 0.01)))
    }

    private func setState(_ state: BoardConnectionState, for id: BoardID) {
        boards[id]?.state = state
        eventBroadcaster.send(.connectionState(id, state))
    }

    private func dropLink(_ id: BoardID, reason: BoardDisconnectReason) {
        guard let state = boards[id]?.state, !isDisconnected(state) else { return }
        boards[id]?.engine.linkDropped()
        setState(.disconnected(reason), for: id)
        if scanning { publishDiscoveries() }
    }

    private func isDisconnected(_ state: BoardConnectionState) -> Bool {
        if case .disconnected = state { return true }
        return false
    }

    private func deliver(_ output: SimulatedBoardEngine.Output, from id: BoardID) {
        guard let board = boards[id] else { return }
        switch output {
        case .status(let status):
            guard board.state.isConnected else { return }
            let frame = BoardFraming.encode(sequence: board.statusSequence, messages: [Self.encode(status)])
            boards[id]?.statusSequence &+= 1
            if let decoded = try? boards[id]?.decoder.decodeStatus(frame) {
                decoded.forEach { eventBroadcaster.send(.status(id, $0)) }
            }
        case .records(let batch):
            if board.state.isConnected {
                notify(batch, from: id)
            } else {
                buffer(batch, for: id)
            }
        case .rawFrames(let frames):
            guard board.state.isConnected else { return }
            for rawFrame in frames {
                guard let sequence = boards[id]?.rawSequence else { return }
                boards[id]?.rawSequence &+= 1
                let frame = BoardFraming.encode(sequence: sequence, messages: [Self.encode(rawFrame)])
                if let received = try? boards[id]?.decoder.decodeRaw(frame, receivedAt: now) {
                    eventBroadcaster.send(.rawFrames(id, received))
                }
            }
        }
    }

    private func notify(_ batch: NSBRecordBatch, from id: BoardID) {
        guard let sequence = boards[id]?.recordSequence else { return }
        boards[id]?.recordSequence &+= 1
        if let lose = boards[id]?.notificationsToLose, lose > 0 {
            boards[id]?.notificationsToLose = lose - 1
            return
        }
        let frame = BoardFraming.encode(sequence: sequence, messages: [Self.encode(batch)])
        guard let received = try? boards[id]?.decoder.decodeRecords(frame, receivedAt: now) else { return }
        received.forEach { eventBroadcaster.send(.records(id, $0)) }
    }

    private func buffer(_ batch: NSBRecordBatch, for id: BoardID) {
        guard var board = boards[id] else { return }
        if board.ringRecords + batch.records.count > Self.ringCapacity {
            board.engine.droppedRecords &+= UInt32(batch.records.count)
        } else {
            board.ring.append(batch)
            board.ringRecords += batch.records.count
        }
        board.engine.ringFillPercent = UInt32(board.ringRecords * 100 / Self.ringCapacity)
        boards[id] = board
    }

    private func flushRing(_ id: BoardID) {
        guard let ring = boards[id]?.ring, !ring.isEmpty else { return }
        boards[id]?.ring = []
        boards[id]?.ringRecords = 0
        boards[id]?.engine.ringFillPercent = 0
        ring.forEach { notify($0, from: id) }
    }

    private func publishDiscoveries() {
        let seen = profiles.compactMap { profile -> DiscoveredBoard? in
            guard let board = boards[profile.id], !board.state.isConnected else { return nil }
            return DiscoveredBoard(
                id: profile.id, name: profile.name, shortID: profile.shortID,
                rssi: profile.advertisingRSSI + Int.random(in: -4...4, using: &rng),
                model: profile.model, protocolMajor: profile.protocolMajor,
                pairingMode: board.engine.pairingMode, hasBond: board.engine.bondCount > 0,
                supports5GHz: profile.bands.contains(.ghz5), isKnown: known[profile.id] != nil,
                isRemoved: known[profile.id]?.isRemoved == true, isSimulated: true, lastSeen: now
            )
        }
        discoveryBroadcaster.send(seen)
    }

    private static func encode(_ message: some SwiftProtobuf.Message) -> Data {
        (try? message.serializedData()) ?? Data()
    }
}
