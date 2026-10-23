import BoardKit
import BoardProtocol
import Foundation
import Synchronization

/// One `BoardTransport` over the two kinds of board the app knows: real boards
/// over Bluetooth and the simulated demo board. `BoardManager` takes a single
/// transport, so this routes each call to the transport that owns the board.
///
/// The Bluetooth transport is attached later (`attachBluetooth`), because
/// creating it asks for Bluetooth access, which the app only does once the
/// user is looking for a board. The demo board can be hidden; while hidden it
/// is not listed and cannot be connected.
nonisolated final class CombinedBoardTransport: BoardTransport, Sendable {
    private struct State {
        var bluetooth: (any BoardTransport)?
        var demoEnabled: Bool
        var scanning = false
        var bluetoothList: [DiscoveredBoard] = []
        var demoList: [DiscoveredBoard] = []
    }

    let demo: SimulatedBoardTransport
    let demoIDs: Set<BoardID>
    private let state: Mutex<State>
    private let discoveryOut = Fanout<[DiscoveredBoard]>(replaysLatest: true)
    private let eventOut = Fanout<BoardEvent>()

    init(demo: SimulatedBoardTransport, demoEnabled: Bool) {
        self.demo = demo
        demoIDs = Set(demo.profiles.map(\.id))
        state = Mutex(State(demoEnabled: demoEnabled))
        pump(from: demo, isDemo: true)
        discoveryOut.send([])
    }

    var bluetooth: (any BoardTransport)? {
        state.withLock { $0.bluetooth }
    }

    /// Adds the Bluetooth transport once; later calls are ignored.
    func attachBluetooth(_ transport: any BoardTransport) async {
        let scanning = state.withLock { state -> Bool? in
            guard state.bluetooth == nil else { return nil }
            state.bluetooth = transport
            return state.scanning
        }
        guard let scanning else { return }
        pump(from: transport, isDemo: false)
        if scanning { await transport.startScanning() }
    }

    func setDemoEnabled(_ enabled: Bool) async {
        let scanning = state.withLock { state -> Bool in
            state.demoEnabled = enabled
            return state.scanning
        }
        if enabled && scanning {
            await demo.startScanning()
        } else if !enabled {
            await demo.stopScanning()
        }
        publish()
    }

    // MARK: - BoardTransport

    func discoveries() -> AsyncStream<[DiscoveredBoard]> {
        discoveryOut.stream()
    }

    func events() -> AsyncStream<BoardEvent> {
        eventOut.stream()
    }

    func startScanning() async {
        let (bluetooth, demoEnabled) = state.withLock { state in
            state.scanning = true
            return (state.bluetooth, state.demoEnabled)
        }
        await bluetooth?.startScanning()
        if demoEnabled { await demo.startScanning() }
    }

    func stopScanning() async {
        let bluetooth = state.withLock { state in
            state.scanning = false
            return state.bluetooth
        }
        await bluetooth?.stopScanning()
        await demo.stopScanning()
    }

    func connect(_ board: BoardID, timeout: Duration?) async throws(BoardTransportError) {
        try await owner(of: board).connect(board, timeout: timeout)
    }

    func disconnect(_ board: BoardID) async {
        guard let owner = try? owner(of: board, allowHiddenDemo: true) else { return }
        await owner.disconnect(board)
    }

    func readInfo(_ board: BoardID) async throws(BoardTransportError) -> NSBBoardInfo {
        try await owner(of: board).readInfo(board)
    }

    func send(
        _ request: NSBControlRequest, to board: BoardID, timeout: Duration
    ) async throws(BoardTransportError) -> NSBControlResponse {
        try await owner(of: board, allowHiddenDemo: true).send(request, to: board, timeout: timeout)
    }

    func maximumOTAWriteLength(for board: BoardID) async -> Int? {
        guard let owner = try? owner(of: board) else { return nil }
        return await owner.maximumOTAWriteLength(for: board)
    }

    func writeOTAChunk(_ chunk: Data, to board: BoardID) async throws(BoardTransportError) {
        try await owner(of: board).writeOTAChunk(chunk, to: board)
    }

    func connectionStates() async -> [BoardID: BoardConnectionState] {
        var states = await demo.connectionStates()
        if let bluetooth { states.merge(await bluetooth.connectionStates()) { $1 } }
        return states
    }

    func knownBoards() async -> [KnownBoard] {
        let demoKnown = state.withLock { $0.demoEnabled } ? await demo.knownBoards() : []
        return (await bluetooth?.knownBoards() ?? []) + demoKnown
    }

    func forgetKnownBoard(_ board: BoardID) async {
        guard let owner = try? owner(of: board, allowHiddenDemo: true) else { return }
        await owner.forgetKnownBoard(board)
    }

    // MARK: - Routing

    func isDemo(_ board: BoardID) -> Bool {
        demoIDs.contains(board)
    }

    private func owner(of board: BoardID, allowHiddenDemo: Bool = false) throws(BoardTransportError) -> any BoardTransport {
        if demoIDs.contains(board) {
            guard allowHiddenDemo || state.withLock({ $0.demoEnabled }) else { throw .unknownBoard }
            return demo
        }
        guard let bluetooth else { throw .bluetoothUnavailable("Bluetooth is not set up yet") }
        return bluetooth
    }

    private func pump(from transport: any BoardTransport, isDemo: Bool) {
        let discoveries = transport.discoveries()
        let events = transport.events()
        Task { [weak self] in
            for await list in discoveries {
                guard let self else { return }
                self.state.withLock { state in
                    if isDemo { state.demoList = list } else { state.bluetoothList = list }
                }
                self.publish()
            }
        }
        Task { [eventOut] in
            for await event in events { eventOut.send(event) }
        }
    }

    private func publish() {
        let list = state.withLock { state in
            state.bluetoothList + (state.demoEnabled ? state.demoList : [])
        }
        discoveryOut.send(list)
    }
}

/// Fans values out to any number of `AsyncStream` subscribers. With
/// `replaysLatest` a new subscriber starts with the last value sent. Values are
/// yielded outside the lock, so a subscriber that ends while a value is on its
/// way cannot deadlock the sender.
nonisolated final class Fanout<Element: Sendable>: Sendable {
    private struct State {
        var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
        var latest: Element?
    }

    private let state = Mutex(State())
    private let replaysLatest: Bool

    init(replaysLatest: Bool = false) {
        self.replaysLatest = replaysLatest
    }

    func stream() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self)
        let id = UUID()
        let latest = state.withLock { state in
            state.continuations[id] = continuation
            return replaysLatest ? state.latest : nil
        }
        if let latest { continuation.yield(latest) }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    func send(_ value: Element) {
        let targets = state.withLock { state in
            if replaysLatest { state.latest = value }
            return Array(state.continuations.values)
        }
        for continuation in targets { continuation.yield(value) }
    }
}
