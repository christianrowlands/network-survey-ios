import BoardProtocol
import Foundation
import Synchronization
import Testing
@testable import BoardKit

/// Waits until `condition` holds, polling; false after `timeout`.
@discardableResult
func eventually(
    isolation: isolated (any Actor)? = #isolation, timeout: Duration = .seconds(5), _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

extension BLEBoardTransport.Timing {
    static let fast = BLEBoardTransport.Timing(
        connect: .seconds(2), gattStep: .seconds(2), pairing: .seconds(2), writeReady: .seconds(1), discoveryExpiry: .seconds(2)
    )
}

/// A transport plus the knobs the shared manager tests need. Implemented by the
/// simulated transport and by the BLE transport over the simulated central, so
/// both run the same tests.
protocol TransportRig: Sendable {
    var transport: any BoardTransport { get }
    /// Stable board IDs, as events and `BoardManager.boards` use them.
    var boardIDs: [BoardID] { get }
    /// The ID to connect a never-paired board with (what a scan shows).
    func key(_ id: BoardID) -> BoardID
    func advance(byMs ms: UInt64) async
    func injectLostNotifications(_ count: Int, on id: BoardID) async
    func injectLinkLoss(_ id: BoardID) async
    func shutdown() async
}

enum RigKind: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case simulatedTransport
    case bleOverSimulatedCentral

    var testDescription: String { rawValue }

    func make(boards: Int = 1, seed: UInt64 = 7, profiles: [SimulatedBoardProfile]? = nil) -> any TransportRig {
        let profiles = profiles ?? SimulatedBoardProfile.standard(count: boards, seed: seed)
        switch self {
        case .simulatedTransport:
            return SimTransportRig(transport: SimulatedBoardTransport(
                profiles: profiles, world: SimulatedWorld(seed: seed), seed: seed, timeSource: .manual
            ))
        case .bleOverSimulatedCentral:
            let central = SimulatedBLECentral(profiles: profiles, seed: seed)
            return BLERig(central: central, store: InMemoryKnownBoardStore())
        }
    }
}

struct SimTransportRig: TransportRig {
    let sim: SimulatedBoardTransport

    init(transport: SimulatedBoardTransport) {
        sim = transport
    }

    var transport: any BoardTransport { sim }
    var boardIDs: [BoardID] { sim.profiles.map(\.id) }
    func key(_ id: BoardID) -> BoardID { id }
    func advance(byMs ms: UInt64) async { await sim.advance(byMs: ms) }
    func injectLostNotifications(_ count: Int, on id: BoardID) async { await sim.injectLostNotifications(count, on: id) }
    func injectLinkLoss(_ id: BoardID) async { await sim.injectDisconnect(id) }
    func shutdown() async { await sim.shutdown() }
}

struct BLERig: TransportRig {
    let central: SimulatedBLECentral
    let store: InMemoryKnownBoardStore
    let ble: BLEBoardTransport

    init(central: SimulatedBLECentral, store: InMemoryKnownBoardStore, timing: BLEBoardTransport.Timing = .fast) {
        self.central = central
        self.store = store
        ble = BLEBoardTransport(central: central, store: store, timing: timing)
    }

    var transport: any BoardTransport { ble }
    var boardIDs: [BoardID] { central.boardIDs }

    func key(_ id: BoardID) -> BoardID {
        central.profiles.first { $0.id == id }.map { BoardID($0.peripheralID) } ?? id
    }

    /// Simulated time moves synchronously; give the transport a moment to
    /// drain the events it produced.
    func advance(byMs ms: UInt64) async {
        var remaining = ms
        while remaining > 0 {
            let step = min(remaining, 500)
            central.advance(byMs: step)
            remaining -= step
            await Task.yield()
        }
        try? await Task.sleep(for: .milliseconds(20))
    }

    func injectLostNotifications(_ count: Int, on id: BoardID) async { central.injectLostNotifications(count, on: id) }
    func injectLinkLoss(_ id: BoardID) async { central.injectLinkLoss(id) }
    func shutdown() async { central.shutdown() }
}

/// Collects a stream into an array on a background task.
final class Collector<Element: Sendable>: Sendable {
    private let items = Mutex<[Element]>([])
    private let task: Mutex<Task<Void, Never>?> = Mutex(nil)

    init(_ stream: AsyncStream<Element>) {
        task.withLock {
            $0 = Task { [weak self] in
                for await item in stream { self?.items.withLock { $0.append(item) } }
            }
        }
    }

    var values: [Element] { items.withLock { $0 } }

    deinit {
        task.withLock { $0?.cancel() }
    }
}

/// A control request with an explicit request ID.
func request(_ id: UInt32, _ command: NSBControlRequest.OneOf_Command) -> NSBControlRequest {
    .with {
        $0.requestID = id
        $0.command = command
    }
}

func ping(_ nonce: UInt32) -> NSBControlRequest.OneOf_Command {
    .ping(.with { $0.nonce = nonce })
}

/// A thread-safe list for values reported from callbacks.
final class Recorder<Element: Sendable>: Sendable {
    private let items = Mutex<[Element]>([])

    func append(_ item: Element) {
        items.withLock { $0.append(item) }
    }

    var values: [Element] { items.withLock { $0 } }
}

extension SimulatedBoardProfile {
    /// The store entry a phone keeps for this board after pairing.
    var knownBoard: KnownBoard { KnownBoard(info: boardInfo, peripheralID: peripheralID, at: Date()) }
}
