import BoardProtocol
import Foundation

extension BLEBoardTransport {
    // MARK: - Central events

    func handle(_ event: BLECentralEvent) {
        switch event {
        case .powerState(let state):
            handlePowerState(state)
        case .restored(let peripherals):
            handleRestored(peripherals)
        case .discovered(let id, let advertisement, let rssi, let name):
            updateDiscovery(id, advertisement, rssi: rssi, name: name)
        case .connected(let id):
            // A connected board stops advertising: forget its last advertisement,
            // so nothing judges the board by one from before this link.
            hadBondBeforeLink[id] = seen.removeValue(forKey: id)?.hasBond
            if waiters[.connect(id)] != nil {
                resolve(.connect(id), .success(.none))
            } else if known[id]?.isRemoved == false {
                adopt(id)
            } else {
                Self.log.notice("dropping a connection nobody asked for")
                central.cancelConnection(id)
            }
        case .connectFailed(let id, let error):
            resolve(.connect(id), .failure(error.map { linkError($0, on: id) } ?? .connectionFailed("connect failed")))
        case .disconnected(let id, let error):
            handleDisconnected(id, error: error)
        case .gattDiscovered(let id, let error):
            resolve(.gatt(id), error.map { .failure(linkError($0, on: id)) } ?? .success(.none))
        case .valueUpdated(let id, let characteristic, let value, let error):
            if waiters[.read(id, characteristic)] != nil {
                resolve(.read(id, characteristic), error.map { .failure(linkError($0, on: id)) } ?? .success(.data(value)))
            } else if error == nil {
                handleNotification(value, from: characteristic, of: id)
            }
        case .wroteValue(let id, let characteristic, let error):
            guard characteristic == .control, let error else { return }
            let mapped = linkError(error, on: id)
            let failure: BoardTransportError = switch mapped {
            case .bondMissing, .pairingRejected, .notConnected: mapped
            default: .writeFailed(error.message)
            }
            resolve(.control(id), .failure(failure))
        case .notifyStateChanged(let id, let characteristic, _, let error):
            resolve(.notify(id, characteristic), error.map { .failure(linkError($0, on: id)) } ?? .success(.none))
        case .readyToWriteWithoutResponse(let id):
            resolve(.writeReady(id), .success(.none))
        }
    }

    private func handlePowerState(_ state: BLEPowerState) {
        eventBroadcaster.send(.bluetooth(state))
        if state == .poweredOn {
            if scanning { central.startScan() }
            if let restored = deferredRestore {
                deferredRestore = nil
                handleRestored(restored)
            }
            return
        }
        // After a power cycle the system has dropped every restored link.
        if state != .unknown, state != .resetting { deferredRestore = nil }
        for (id, link) in links where !link.state.isDisconnected || link.setupRunning {
            failWaiters(for: id, with: .bluetoothUnavailable(state.rawValue))
            markDisconnected(id, reason: .linkLost)
        }
    }

    /// Restoration arrives before the power state. Until Bluetooth is on, cancels
    /// are ignored and GATT calls fail, so the list waits for `.poweredOn`.
    private func handleRestored(_ peripherals: [BLERestoredPeripheral]) {
        guard central.powerState == .poweredOn else {
            deferredRestore = (deferredRestore ?? []) + peripherals
            return
        }
        for peripheral in peripherals {
            guard known[peripheral.id]?.isRemoved == false else {
                central.cancelConnection(peripheral.id)
                continue
            }
            switch peripheral.state {
            case .connected:
                adopt(peripheral.id)
            case .connecting:
                // The restored pending connect completes as an unrequested `.connected`.
                setState(.connecting, for: peripheral.id)
            case .disconnected:
                break
            }
        }
    }

    private func handleDisconnected(_ id: UUID, error: BLEError?) {
        // A link that is still connecting cannot drop: this is the late report of
        // an earlier cancel, which the central delivers before the new connect.
        guard waiters[.connect(id)] == nil else { return }
        let reason: BoardDisconnectReason =
            if links[id]?.disconnectRequested == true { .requested }
            else if let error, linkError(error, on: id) == .bondMissing { .bondMissing }
            else { .linkLost }
        failWaiters(for: id, with: reason == .bondMissing ? .bondMissing : .notConnected)
        markDisconnected(id, reason: reason)
    }

    func markDisconnected(_ id: UUID, reason: BoardDisconnectReason) {
        guard let link = links[id], !link.state.isDisconnected else { return }
        links[id]?.pendingRequestID = nil
        setState(.disconnected(reason), for: id)
        if scanning { publishDiscoveries() }
    }

    func setState(_ state: BoardConnectionState, for id: UUID) {
        guard links[id]?.state != state else { return }
        links[id, default: Link()].state = state
        eventBroadcaster.send(.connectionState(publicID(id), state))
    }

    // MARK: - Notifications

    private func handleNotification(_ value: Data, from characteristic: BoardCharacteristic, of id: UUID) {
        guard links[id] != nil else { return }
        let board = publicID(id)
        do {
            switch characteristic {
            case .records:
                let batches = try links[id]?.decoder.decodeRecords(value, receivedAt: Date()) ?? []
                batches.forEach { eventBroadcaster.send(.records(board, $0)) }
            case .status:
                let statuses = try links[id]?.decoder.decodeStatus(value) ?? []
                statuses.forEach { eventBroadcaster.send(.status(board, $0)) }
            case .raw:
                if let frames = try links[id]?.decoder.decodeRaw(value, receivedAt: Date()) {
                    eventBroadcaster.send(.rawFrames(board, frames))
                }
            case .ota:
                let acks = try links[id]?.decoder.decodeOtaAcks(value) ?? []
                acks.forEach { eventBroadcaster.send(.otaAck(board, $0)) }
            case .control:
                let responses = try links[id]?.decoder.decodeControl(value) ?? []
                responses.forEach { deliverControlResponse($0, from: id) }
            case .info:
                break
            }
        } catch {
            Self.log.error("undecodable \(characteristic.rawValue, privacy: .public) notification: \(String(describing: error), privacy: .public)")
        }
    }

    /// One request is outstanding per board, so a response matches it by ID, or
    /// by ID 0 (the board could not read the request). Anything else is a late
    /// answer to a request that already timed out.
    private func deliverControlResponse(_ response: NSBControlResponse, from id: UUID) {
        guard let pending = links[id]?.pendingRequestID, response.requestID == pending || response.requestID == 0 else {
            Self.log.notice("ignoring control response \(response.requestID) with no matching request")
            return
        }
        links[id]?.pendingRequestID = nil
        resolve(.control(id), .success(.response(response)))
    }

    // MARK: - Discovery

    private func updateDiscovery(_ id: UUID, _ advertisement: BLEAdvertisementData, rssi: Int, name: String?) {
        let now = Date()
        let existing = seen[id]
        let advertisedName = advertisement.localName ?? name
        guard let data = advertisement.manufacturerData, let parsed = BoardAdvertisement.parse(manufacturerData: data) else {
            // A scan response on its own carries only the name.
            if var board = existing, let shortID = BoardAdvertisement.shortID(fromName: advertisedName) {
                board.shortID = shortID
                board.name = "NS-\(shortID)"
                board.lastSeen = now
                seen[id] = board
            }
            return
        }
        let shortID = BoardAdvertisement.shortID(fromName: advertisedName) ?? existing?.shortID ?? known[id]?.shortID ?? "????"
        let board = DiscoveredBoard(
            id: publicID(id), name: "NS-\(shortID)", shortID: shortID, rssi: rssi, model: parsed.model,
            protocolMajor: UInt32(parsed.protocolMajor), pairingMode: parsed.pairable, hasBond: parsed.hasBond,
            hasGPS: parsed.hasGPS, supports5GHz: parsed.supports5GHz, isKnown: known[id] != nil,
            isRemoved: known[id]?.isRemoved == true, isSimulated: false, lastSeen: now
        )
        seen[id] = board
        let changed = existing.map {
            $0.id != board.id || $0.shortID != board.shortID || $0.pairingMode != board.pairingMode || $0.hasBond != board.hasBond
        } ?? true
        if changed || now.timeIntervalSince(lastPublish) >= 0.5 { publishDiscoveries() }
    }

    func pruneDiscoveries() {
        let cutoff = Date().addingTimeInterval(-Double(timing.discoveryExpiry.components.seconds))
        let before = seen.count
        seen = seen.filter { $0.value.lastSeen >= cutoff }
        if seen.count != before { publishDiscoveries() }
    }

    func publishDiscoveries() {
        lastPublish = Date()
        let visible = seen
            .filter { links[$0.key]?.state.isConnected != true }
            .map { peripheral, board -> DiscoveredBoard in
                var board = board
                board.isKnown = known[peripheral] != nil
                board.isRemoved = known[peripheral]?.isRemoved == true
                return board
            }
            .sorted { ($0.rssi, $0.shortID) > ($1.rssi, $1.shortID) }
        discoveryBroadcaster.send(visible)
    }

    // MARK: - Waiting for events

    /// Registers a waiter for `key`, runs `issue` (which starts the operation)
    /// and suspends until the matching event, a failure or the timeout.
    func wait(_ key: WaitKey, timeout: Duration?, _ issue: () -> Void) async -> Result<WaitValue, BoardTransportError> {
        nextToken &+= 1
        let token = nextToken
        return await withCheckedContinuation { continuation in
            if let previous = waiters.removeValue(forKey: key) {
                previous.timeoutTask?.cancel()
                previous.continuation.resume(returning: .failure(.cancelled))
            }
            var waiter = Waiter(token: token, continuation: continuation)
            if let timeout {
                waiter.timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.resolve(key, .failure(.timeout), token: token)
                }
            }
            waiters[key] = waiter
            issue()
        }
    }

    func step(_ key: WaitKey, timeout: Duration?, _ issue: () -> Void) async throws(BoardTransportError) -> WaitValue {
        try await wait(key, timeout: timeout, issue).get()
    }

    func resolve(_ key: WaitKey, _ result: Result<WaitValue, BoardTransportError>, token: UInt64? = nil) {
        guard let waiter = waiters[key], token == nil || waiter.token == token else { return }
        waiters[key] = nil
        waiter.timeoutTask?.cancel()
        waiter.continuation.resume(returning: result)
    }

    func failWaiters(for id: UUID, with error: BoardTransportError) {
        for key in waiters.keys where key.peripheral == id {
            resolve(key, .failure(error))
        }
    }
}
