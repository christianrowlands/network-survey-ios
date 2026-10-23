import BoardProtocol
import Foundation
import Synchronization

/// A `BLECentral` whose peripherals are simulated boards. `BLEBoardTransport`
/// on top of it runs exactly the code it runs on CoreBluetooth: advertising
/// parsing, pairing errors, framing, control correlation and OTA flow control.
///
/// Time moves with `advance(byMs:)`, or on its own after `startClock(speed:)`.
/// Hooks inject faults: lost notifications and control responses, link loss,
/// connect failures, stale bonds (CBError 14) and lost OTA chunks.
public final class SimulatedBLECentral: BLECentral {
    struct State {
        var power: BLEPowerState = .poweredOn
        var scanning = false
        var peripherals: [UUID: SimulatedPeripheral] = [:]
        var simTimeMs: UInt64 = 0
    }

    public let profiles: [SimulatedBoardProfile]
    public let world: SimulatedWorld
    let state: Mutex<State>
    private let stream: AsyncStream<BLECentralEvent>
    let continuation: AsyncStream<BLECentralEvent>.Continuation
    private let clock = Mutex<Task<Void, Never>?>(nil)

    /// - Parameter pairedWithPhone: indexes of boards that already hold this phone's bond.
    public convenience init(boardCount: Int = 1, seed: UInt64 = 1, pairedWithPhone: Set<Int> = []) {
        self.init(profiles: SimulatedBoardProfile.standard(count: boardCount, seed: seed), seed: seed, pairedWithPhone: pairedWithPhone)
    }

    public init(profiles: [SimulatedBoardProfile], seed: UInt64, pairedWithPhone: Set<Int> = []) {
        let world = SimulatedWorld(seed: seed)
        self.profiles = profiles
        self.world = world
        var state = State()
        for (index, profile) in profiles.enumerated() {
            state.peripherals[profile.peripheralID] = SimulatedPeripheral(
                id: profile.peripheralID, engine: SimulatedBoardEngine(profile: profile, world: world, seed: seed),
                pairedWithPhone: pairedWithPhone.contains(index)
            )
        }
        self.state = Mutex(state)
        (stream, continuation) = AsyncStream.makeStream(of: BLECentralEvent.self)
        continuation.yield(.powerState(.poweredOn))
    }

    deinit {
        clock.withLock { $0?.cancel() }
    }

    /// Stable board IDs (what events carry once Info has been read).
    public var boardIDs: [BoardID] { profiles.map(\.id) }

    /// Provisional IDs, as a scan shows boards this phone has not paired with.
    public var peripheralIDs: [BoardID] { profiles.map { BoardID($0.peripheralID) } }

    /// The peripheral for a stable or provisional board ID.
    func key(_ board: BoardID) -> UUID {
        profiles.first { $0.id == board }?.peripheralID ?? board.peripheralUUID ?? UUID()
    }

    // MARK: - BLECentral

    public func events() -> AsyncStream<BLECentralEvent> { stream }

    public var powerState: BLEPowerState { state.withLock { $0.power } }

    public func startScan() {
        state.withLock { state in
            state.scanning = true
            advertise(&state)
        }
    }

    public func stopScan() {
        state.withLock { $0.scanning = false }
    }

    public func knownPeripherals(_ ids: [UUID]) -> [UUID] {
        state.withLock { state in ids.filter { state.peripherals[$0] != nil } }
    }

    public func connect(_ id: UUID) {
        update(id, offline: [.connectFailed(id, BLEError(kind: .notConnected, message: "Bluetooth is not on"))]) { peripheral, _ in
            guard !peripheral.connected else { return [.connected(id)] }
            if peripheral.connectFailures > 0 {
                peripheral.connectFailures -= 1
                return [.connectFailed(id, BLEError(domain: BLEError.cbErrorDomain, code: 10, message: "Connection failed"))]
            }
            guard peripheral.inRange else {
                peripheral.connecting = true  // Pending until the board is back in range.
                return []
            }
            peripheral.connected = true
            return [.connected(id)]
        }
    }

    /// Like CoreBluetooth, a cancel while Bluetooth is not on does nothing.
    public func cancelConnection(_ id: UUID) {
        update(id, offline: []) { peripheral, _ in
            peripheral.connecting = false
            guard peripheral.connected else { return [] }
            peripheral.dropLink()
            return [.disconnected(id, nil)]
        }
    }

    public func discoverGATT(_ id: UUID) {
        update(id, offline: [.gattDiscovered(id, BLEError(kind: .notConnected, message: "Bluetooth is not on"))]) { peripheral, _ in
            [.gattDiscovered(id, peripheral.connected ? nil : BLEError(kind: .notConnected))]
        }
    }

    public func read(_ characteristic: BoardCharacteristic, on id: UUID) {
        update(id, offline: [.valueUpdated(id, characteristic, Data(), BLEError(kind: .notConnected, message: "Bluetooth is not on"))]) { peripheral, _ in
            guard peripheral.connected else { return [.valueUpdated(id, characteristic, Data(), BLEError(kind: .notConnected))] }
            guard characteristic == .info else {
                return [.valueUpdated(id, characteristic, Data(), BLEError(domain: BLEError.attErrorDomain, code: 0x02))]
            }
            return [.valueUpdated(id, .info, SimulatedPeripheral.encode(peripheral.profile.boardInfo), nil)]
        }
    }

    public func setNotify(_ enabled: Bool, for characteristic: BoardCharacteristic, on id: UUID) {
        update(id, offline: [.notifyStateChanged(id, characteristic, enabled: false, BLEError(kind: .notConnected, message: "Bluetooth is not on"))]) { peripheral, _ in
            guard peripheral.connected else {
                return [.notifyStateChanged(id, characteristic, enabled: false, BLEError(kind: .notConnected))]
            }
            return peripheral.subscribe(characteristic, enabled: enabled)
        }
    }

    public func write(_ value: Data, to characteristic: BoardCharacteristic, on id: UUID, withResponse: Bool) {
        var replenish = false
        update(id) { peripheral, now in
            guard peripheral.connected else {
                return withResponse ? [.wroteValue(id, characteristic, BLEError(kind: .notConnected))] : []
            }
            switch characteristic {
            case .control:
                let (events, disconnect) = peripheral.writeControl(value, nowMs: now)
                guard disconnect else { return events }
                peripheral.dropLink()
                return events + [.disconnected(id, BLEError(domain: BLEError.cbErrorDomain, code: 7))]
            case .ota:
                let events = peripheral.writeOTA(value)
                replenish = peripheral.credits == 0
                return events
            default:
                return withResponse ? [.wroteValue(id, characteristic, BLEError(domain: BLEError.attErrorDomain, code: 0x03))] : []
            }
        }
        if replenish { scheduleCredits(id) }
    }

    public func canSendWriteWithoutResponse(_ id: UUID) -> Bool {
        state.withLock { ($0.peripherals[id]?.credits ?? 0) > 0 }
    }

    public func maximumWriteLength(_ id: UUID, withResponse: Bool) -> Int {
        state.withLock { state in
            withResponse ? BoardLimits.controlRequestBytes : Int(state.peripherals[id]?.profile.mtu ?? 23) - 3
        }
    }

    // MARK: - Time

    /// Moves simulated time forward: boards survey, notify and advertise.
    public func advance(byMs ms: UInt64) {
        state.withLock { state in
            var remaining = ms
            while remaining > 0 {
                let step = min(remaining, SimulatedBoardTransport.tickMs)
                remaining -= step
                state.simTimeMs += step
                for id in profiles.map(\.peripheralID) {
                    guard var peripheral = state.peripherals[id] else { continue }
                    let events = peripheral.advance(byMs: step, nowMs: state.simTimeMs)
                    state.peripherals[id] = peripheral
                    events.forEach { continuation.yield($0) }
                }
                if state.scanning, state.simTimeMs % 1000 < step { advertise(&state) }
            }
        }
    }

    /// Advances time in real time (scaled by `speed`) on a background task.
    public func startClock(speed: Double = 1) {
        let interval = Duration.milliseconds(Double(SimulatedBoardTransport.tickMs) / max(speed, 0.01))
        clock.withLock { task in
            task?.cancel()
            task = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    self?.advance(byMs: SimulatedBoardTransport.tickMs)
                }
            }
        }
    }

    /// Stops the clock and ends the event stream.
    public func shutdown() {
        clock.withLock { $0?.cancel() }
        continuation.finish()
    }

    // MARK: - Internals

    /// Runs `body` on one peripheral under the lock and yields its events. With
    /// `offline`, Bluetooth must be on, else those events are yielded instead.
    func update(
        _ id: UUID, offline: [BLECentralEvent]? = nil, _ body: (inout SimulatedPeripheral, UInt64) -> [BLECentralEvent]
    ) {
        state.withLock { state in
            guard var peripheral = state.peripherals[id] else { return }
            if let offline, state.power != .poweredOn {
                offline.forEach { continuation.yield($0) }
                return
            }
            let events = body(&peripheral, state.simTimeMs)
            state.peripherals[id] = peripheral
            events.forEach { continuation.yield($0) }
        }
    }

    private func advertise(_ state: inout State) {
        for id in profiles.map(\.peripheralID) {
            guard let peripheral = state.peripherals[id], peripheral.advertising else { continue }
            let rssi = peripheral.profile.advertisingRSSI + Int(state.simTimeMs / 1000 % 5) - 2
            continuation.yield(.discovered(id, peripheral.advertisement, rssi: rssi, name: peripheral.profile.name))
        }
    }

    /// The link has room again a moment later, as `peripheralIsReady` reports it.
    private func scheduleCredits(_ id: UUID) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2))
            self?.update(id) { peripheral, _ in
                peripheral.credits = SimulatedPeripheral.writeCredits
                return [.readyToWriteWithoutResponse(id)]
            }
        }
    }
}
