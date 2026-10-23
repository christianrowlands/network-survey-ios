import BoardProtocol
import Foundation

extension BoardManager {
    // MARK: - Survey and channel split

    /// Plans the channel split across the ready boards, then sends Configure and
    /// Start to each. Boards that join, rejoin or leave later are planned again.
    /// Throws when no board could be started. Counters (`counters(for:)`) and
    /// the channel activity used for the split start from zero.
    @discardableResult
    public func startSurvey(_ capture: SurveyCapture) async throws -> [BoardID: BoardAssignment] {
        guard !readyBoards.isEmpty else { throw BoardManagerError.notReady }
        router.beginSurvey()
        for id in boards.keys { boards[id]?.counters = BoardCounters() }
        self.capture = capture
        let plan = await rebalance(force: Set(readyBoards))
        let started = readyBoards.filter { boards[$0]?.assignment != nil && boards[$0]?.issue == nil }
        guard !started.isEmpty else {
            self.capture = nil
            let issue = readyBoards.compactMap { boards[$0]?.issue }.first
            throw issue.map { BoardManagerError.rejected(.error, "\($0)") } ?? BoardManagerError.notReady
        }
        return plan
    }

    /// Stops every board. Waits for a re-plan in progress, which sees the survey
    /// end and stops configuring, so no board is started after this returns.
    public func stopSurvey() async {
        capture = nil
        resplitTask?.cancel()
        resplitTask = nil
        await acquireRebalanceGate()
        defer { releaseRebalanceGate() }
        for id in readyBoards {
            _ = try? await stop(id)
            boards[id]?.assignment = nil
        }
    }

    /// Sets a board's role; replans right away while a survey runs.
    public func setRole(_ role: BoardRolePreference, for id: BoardID) async {
        roles[id] = role
        await rebalance()
    }

    /// Plans the ready boards and reconfigures those whose assignment changed,
    /// plus `force` (boards that just connected, which may have rebooted).
    /// Runs one at a time; does nothing without a running survey.
    @discardableResult
    func rebalance(force: Set<BoardID> = []) async -> [BoardID: BoardAssignment] {
        guard capture != nil else { return [:] }
        await acquireRebalanceGate()
        defer { releaseRebalanceGate() }
        guard let capture else { return [:] }
        let ready = readyBoards
        let plan = ChannelPlanner.plan(
            ready.compactMap { id in
                boards[id]?.info.map { ChannelPlanner.Board(id: id, bands: $0.bands, role: roles[id] ?? .auto) }
            },
            options: ChannelPlanner.Options(
                wifi: capture.wifi, ble: capture.ble, channels: capture.channels, weights: router.channelWeights(),
                autoBLESniffer: capture.autoBLESniffer
            )
        )
        for id in ready {
            let assignment = plan[id] ?? .idle
            guard force.contains(id) || boards[id]?.assignment != assignment else { continue }
            guard self.capture != nil else { break }  // stopSurvey ran while we waited on a board.
            do {
                if assignment.isIdle {
                    try await stop(id)
                } else {
                    try await configure(id, capture.configure(for: assignment))
                    guard self.capture != nil else { break }
                    try await start(id)
                }
                boards[id]?.assignment = assignment
                if case .configureFailed? = boards[id]?.issue { boards[id]?.issue = nil }
            } catch {
                boards[id]?.assignment = nil
                boards[id]?.issue = .configureFailed(String(describing: error))
            }
        }
        if self.capture != nil { eventOut.send(.assignmentsChanged(plan)) }
        return plan
    }

    /// Re-plans and stopSurvey run one at a time.
    func acquireRebalanceGate() async {
        if rebalancing {
            await withCheckedContinuation { rebalanceQueue.append($0) }
        }
        rebalancing = true
    }

    func releaseRebalanceGate() {
        if rebalanceQueue.isEmpty {
            rebalancing = false
        } else {
            rebalanceQueue.removeFirst().resume()  // Ownership passes to the next waiter.
        }
    }

    /// After a link loss the dropped board keeps its channels for `resplitGrace`
    /// (it keeps surveying and buffering), then the others take them over.
    func scheduleResplit() {
        guard capture != nil else { return }
        resplitTask?.cancel()
        resplitTask = Task { [weak self, resplitGrace] in
            try? await Task.sleep(for: resplitGrace)
            guard !Task.isCancelled else { return }
            await self?.rebalance()
        }
    }

    // MARK: - Reconnect

    func beginGap(_ id: BoardID) {
        guard gapStarts[id] == nil else { return }
        let now = Date()
        gapStarts[id] = now
        router.noteLinkGap(id)
        eventOut.send(.linkGapStarted(id, at: now))
    }

    func endGap(_ id: BoardID, resumed: Bool) {
        guard let start = gapStarts.removeValue(forKey: id) else { return }
        eventOut.send(.linkGapEnded(id, duration: Date().timeIntervalSince(start), resumed: resumed))
    }

    /// Retries with backoff while the board is wanted. Bond, pairing and
    /// compatibility failures stop the loop: they need the user.
    func startReconnect(_ id: BoardID) {
        reconnectTasks[id]?.cancel()
        reconnectTasks[id] = Task { [weak self] in
            await self?.reconnectLoop(id)
        }
    }

    private func reconnectLoop(_ id: BoardID) async {
        var attempt = 0
        while !Task.isCancelled, wanted.contains(id) {
            attempt += 1
            boards[id, default: BoardState()].reconnect = ReconnectState(attempt: attempt, nextAttempt: nil)
            do {
                try await establish(id)
                // The link dropped again while re-planning: go around once more.
                if droppedWhileBusy.remove(id) != nil {
                    beginGap(id)
                    continue
                }
                break
            } catch {
                droppedWhileBusy.remove(id)
                if Self.needsUser(error) {
                    if let transportError = error as? BoardTransportError { note(transportError, for: id) }
                    stopWanting(id)
                    break
                }
                if case BoardTransportError.bluetoothUnavailable = error {
                    // A backoff would only delay the reconnect once Bluetooth is back.
                    await waitForBluetooth()
                    attempt = 0
                    continue
                }
                eventOut.send(.reconnectAttemptFailed(id, attempt: attempt, error: String(describing: error)))
                let delay = reconnectPolicy.delay(afterAttempt: attempt)
                boards[id]?.reconnect?.nextAttempt = Date().addingTimeInterval(delay.seconds)
                try? await Task.sleep(for: delay)
            }
        }
        guard !Task.isCancelled else { return }
        reconnectTasks[id] = nil
        boards[id]?.reconnect = nil
        endGap(id, resumed: boards[id]?.isReady == true)
    }

    /// Waits until the transport reports Bluetooth on (bounded, in case the
    /// event was missed).
    private func waitForBluetooth() async {
        let deadline = ContinuousClock.now + reconnectPolicy.maxDelay
        while !Task.isCancelled, bluetoothState != .poweredOn, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Connects if needed, says Hello, and puts the board back into the survey.
    /// A link loss meanwhile is left in `droppedWhileBusy` for the caller.
    func establish(_ id: BoardID) async throws {
        beginBusy(id)
        defer { busy.remove(id) }
        if boards[id]?.connection.isConnected != true {
            try await transport.connect(id, timeout: reconnectPolicy.attemptTimeout)
        }
        try await handshake(id)
        await rebalance(force: [id])
    }

    /// The transport connected a known board by itself (state restoration). It
    /// goes through the reconnect loop, so a failed handshake is retried.
    func adopt(_ id: BoardID) {
        guard wanted.contains(id) || wanted.count < Self.maxBoards else {
            Task { await transport.disconnect(id) }
            return
        }
        wanted.insert(id)
        startReconnect(id)
    }

    func stopWanting(_ id: BoardID) {
        wanted.remove(id)
        reconnectTasks.removeValue(forKey: id)?.cancel()
        boards[id]?.reconnect = nil
        endGap(id, resumed: false)
    }

    static func needsUser(_ error: any Error) -> Bool {
        switch error {
        case BoardTransportError.bondMissing, BoardTransportError.pairingRejected, BoardTransportError.unknownBoard: true
        case BoardManagerError.incompatible: true
        default: false
        }
    }
}
