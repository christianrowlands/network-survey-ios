import BoardProtocol
import Foundation

extension SimulatedBLECentral {
    // MARK: - Fault injection and inspection

    /// Loses the next `count` Records notifications (a sequence gap).
    public func injectLostNotifications(_ count: Int, on board: BoardID) {
        update(key(board)) { peripheral, _ in
            peripheral.notificationsToLose += count
            return []
        }
    }

    /// Drops the next `count` control responses, so the phone times out.
    public func dropControlResponses(_ count: Int, on board: BoardID) {
        update(key(board)) { peripheral, _ in
            peripheral.controlResponsesToDrop += count
            return []
        }
    }

    /// Answers control requests after `ms` of simulated time.
    public func setControlLatency(ms: UInt64, on board: BoardID) {
        update(key(board)) { peripheral, _ in
            peripheral.controlLatencyMs = ms
            return []
        }
    }

    /// The link drops (supervision timeout). With `outOfRange` the board stays
    /// unreachable, so a pending connect waits until `setInRange(true)`.
    public func injectLinkLoss(_ board: BoardID, outOfRange: Bool = false) {
        update(key(board)) { peripheral, _ in
            peripheral.inRange = !outOfRange
            guard peripheral.connected else { return [] }
            peripheral.dropLink()
            return [.disconnected(key(board), BLEError(domain: BLEError.cbErrorDomain, code: 6, message: "The connection has timed out."))]
        }
    }

    public func setInRange(_ inRange: Bool, _ board: BoardID) {
        update(key(board)) { peripheral, _ in
            peripheral.inRange = inRange
            guard inRange, peripheral.connecting else { return [] }
            peripheral.connecting = false
            peripheral.connected = true
            return [.connected(key(board))]
        }
    }

    public func failNextConnects(_ count: Int, on board: BoardID) {
        update(key(board)) { peripheral, _ in
            peripheral.connectFailures += count
            return []
        }
    }

    /// The board wipes its bonds (button hold); the phone keeps its stale half.
    public func wipeBondsOnBoard(_ board: BoardID) {
        update(key(board)) { peripheral, _ in
            peripheral.engine.bondCount = 0
            if peripheral.phoneBonded { peripheral.staleBondOnPhone = true }
            peripheral.phoneBonded = false
            return []
        }
    }

    /// The user chose Forget This Device in Settings > Bluetooth.
    public func forgetOnPhone(_ board: BoardID) {
        update(key(board)) { peripheral, _ in
            peripheral.staleBondOnPhone = false
            peripheral.phoneBonded = false
            return []
        }
    }

    /// Another phone owns the board's only bond and no pairing window is open.
    public func bondToAnotherPhone(_ board: BoardID) {
        update(key(board)) { peripheral, _ in
            peripheral.engine.bondCount = 1
            peripheral.engine.pairingMode = false
            peripheral.phoneBonded = false
            return []
        }
    }

    public func setUserAcceptsPairing(_ accepts: Bool, on board: BoardID) {
        update(key(board)) { peripheral, _ in
            peripheral.userAcceptsPairing = accepts
            return []
        }
    }

    /// The next `count` control writes arrive garbled: the board answers
    /// INVALID_ARGUMENT with request ID 0.
    public func corruptControlWrites(_ count: Int, on board: BoardID) {
        update(key(board)) { peripheral, _ in
            peripheral.controlWritesToCorrupt += count
            return []
        }
    }

    /// Most image bytes the phone had sent beyond the board's last OTA ack.
    public func maxOTABytesAheadOfAck(_ board: BoardID) -> Int {
        state.withLock { $0.peripherals[key(board)]?.maxOTABytesAheadOfAck ?? 0 }
    }

    /// Loses OTA writes by their 1-based position in the transfer.
    public func dropOTAChunks(_ positions: Set<Int>, on board: BoardID) {
        update(key(board)) { peripheral, _ in
            peripheral.otaChunksToDrop = positions
            return []
        }
    }

    public func setPowerState(_ power: BLEPowerState) {
        state.withLock { state in
            state.power = power
            continuation.yield(.powerState(power))
            guard power != .poweredOn else { return }
            for id in profiles.map(\.peripheralID) where state.peripherals[id]?.connected == true {
                state.peripherals[id]?.dropLink()
                continuation.yield(.disconnected(id, BLEError(kind: .notConnected)))
            }
        }
    }

    /// Plays a state restoration: the listed boards are connected (or have a
    /// pending connect) as if the system kept them across an app relaunch. With
    /// `poweredOn` false the restoration arrives before Bluetooth reports on, as
    /// on a device; call `setPowerState(.poweredOn)` afterwards.
    public func simulateRestoration(connected: [BoardID], connecting: [BoardID] = [], poweredOn: Bool = true) {
        state.withLock { state in
            if !poweredOn { state.power = .unknown }
            for id in connected.map(key) {
                let bonded = state.peripherals[id]?.phoneBonded ?? false
                state.peripherals[id]?.connected = true
                state.peripherals[id]?.encrypted = bonded
            }
            for id in connecting.map(key) {
                state.peripherals[id]?.connecting = true
                state.peripherals[id]?.inRange = false
            }
            continuation.yield(.restored(
                connected.map { BLERestoredPeripheral(id: key($0), state: .connected) }
                    + connecting.map { BLERestoredPeripheral(id: key($0), state: .connecting) }
            ))
        }
    }

    public func isConnected(_ board: BoardID) -> Bool {
        state.withLock { $0.peripherals[key(board)]?.connected ?? false }
    }

    /// Loses the first OTA ack that reports `nextOffset` (for example the final one).
    public func dropOTAAck(atOffset nextOffset: Int, on board: BoardID) {
        update(key(board)) { peripheral, _ in
            peripheral.otaAckOffsetsToDrop.insert(UInt32(nextOffset))
            return []
        }
    }

    public func isBonded(_ board: BoardID) -> Bool {
        state.withLock { $0.peripherals[key(board)]?.phoneBonded ?? false }
    }

    public func maxOutstandingControl(_ board: BoardID) -> Int {
        state.withLock { $0.peripherals[key(board)]?.maxOutstandingControl ?? 0 }
    }

    public func installedImage(_ board: BoardID) -> Data? {
        state.withLock { $0.peripherals[key(board)]?.installedImage }
    }

    public func receivedOTABytes(_ board: BoardID) -> Data? {
        state.withLock { $0.peripherals[key(board)]?.ota?.image }
    }
}
