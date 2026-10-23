import BoardProtocol
import Foundation

extension BoardManager {
    // MARK: - Handshake

    /// Hello, then SetTime corrected by half a Ping round trip.
    func handshake(_ id: BoardID) async throws {
        let response = try await send(.hello(.current(appVersion: appVersion)), to: id)
        let result: NSBHelloResult? = if case .hello(let hello)? = response.payload { hello } else { nil }
        if response.result == .incompatible || (response.result == .ok && result?.compatible == false) {
            let reason = Self.incompatibilityReason(boardMajor: result?.protocolMajor ?? boards[id]?.info?.protocolMajor)
            boards[id]?.compatibility = .incompatible(reason: reason)
            boards[id]?.issue = .incompatible(reason)
            eventOut.send(.incompatible(id, reason: reason))
            throw BoardManagerError.incompatible(reason)
        }
        try expectOK(response)
        boards[id]?.hello = result
        boards[id]?.compatibility = .compatible(firmwareVersion: result?.firmwareVersion ?? boards[id]?.info?.firmwareVersion ?? "")
        let started = ContinuousClock.now
        let ping = try? await send(.ping(.with { $0.nonce = UInt32.random(in: 1...UInt32.max) }), to: id)
        let halfTrip = ping?.result == .ok ? (ContinuousClock.now - started) / 2 : .zero
        let unixMs = (Date().timeIntervalSince1970 + halfTrip.seconds) * 1000
        try await expectOK(send(.setTime(.with { $0.unixTimeMs = UInt64(unixMs) }), to: id))
        boards[id]?.isReady = true
        boards[id]?.issue = nil
        eventOut.send(.ready(id))
    }

    static func incompatibilityReason(boardMajor: UInt32?) -> String {
        let app = UInt32(NSBProtocolVersion.major.rawValue)
        guard let board = boardMajor else { return "The board did not accept this app's protocol version \(app)." }
        if board < app {
            return "The board firmware speaks protocol \(board), this app needs \(app). Update the board firmware."
        }
        return "The board firmware speaks protocol \(board), newer than this app (\(app)). Update the app."
    }

    // MARK: - Connection state

    func handleConnection(_ id: BoardID, _ state: BoardConnectionState) {
        boards[id, default: BoardState()].connection = state
        switch state {
        case .connecting:
            break
        case .connected(let info):
            boards[id]?.info = info
            // A known board the transport connected on its own (state restoration).
            // Events lag, so check the link is still up: after a failed connect
            // the manager has already disconnected the board.
            if canAdopt(id) {
                let mark = releases[id, default: 0]
                Task { [weak self, transport] in
                    // A connect by provisional ID may be about to claim this board
                    // under its stable ID; wait until it has.
                    while let self, self.busy.contains(where: { !$0.isStable }) {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    guard await transport.connectionStates()[id]?.isConnected == true, let self, self.canAdopt(id),
                          self.releases[id, default: 0] == mark
                    else { return }
                    self.adopt(id)
                }
            }
        case .disconnected(let reason):
            boards[id]?.isReady = false
            boards[id]?.counters = router.counters(id)
            eventOut.send(.disconnected(id, reason))
            switch reason {
            case .bondMissing?:
                note(.bondMissing, for: id)
            case .pairingRejected?:
                note(.pairingRejected, for: id)
            case .linkLost?, .failed?:
                if busy.contains(id) { droppedWhileBusy.insert(id) }
                if wanted.contains(id), !busy.contains(id), reconnectTasks[id] == nil {
                    beginGap(id)
                    startReconnect(id)
                }
            case .requested?, nil:
                break
            }
            scheduleResplit()
        }
    }

    private func canAdopt(_ id: BoardID) -> Bool {
        !busy.contains(id) && !updating.contains(id) && reconnectTasks[id] == nil && boards[id]?.isReady != true
    }

    /// Bond and pairing failures need the user, so the board is no longer reconnected.
    func note(_ error: BoardTransportError, for id: BoardID) {
        switch error {
        case .bondMissing:
            stopWanting(id)
            guard boards[id]?.issue != .bondMissing else { return }
            boards[id, default: BoardState()].issue = .bondMissing
            eventOut.send(.bondMissing(id))
        case .pairingRejected:
            stopWanting(id)
            guard boards[id]?.issue != .pairingRejected else { return }
            boards[id, default: BoardState()].issue = .pairingRejected
            eventOut.send(.pairingRejected(id))
        default:
            break
        }
    }
}
