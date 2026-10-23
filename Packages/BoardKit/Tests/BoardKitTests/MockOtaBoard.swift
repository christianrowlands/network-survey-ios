import BoardProtocol
import CryptoKit
import Foundation
import Synchronization
@testable import BoardKit

/// A one-board transport with a scriptable OTA receiver that follows
/// protocol.md section 10 the way the firmware does: OtaBegin resumes the same
/// image, acks every window/2 bytes and at the end, OUT_OF_ORDER once per gap,
/// a resend ending at next_offset is answered with an OK ack, one running past
/// it is trimmed, other resends get an OK ack at most once a second, OtaEnd
/// checks the SHA-256 and restarts the board.
final class MockOtaBoard: BoardTransport {
    struct Faults {
        /// OTA writes (1-based, counted over the whole test) lost on the air.
        var dropWrites: Set<Int> = []
        /// Acks (1-based) the board sends but the phone never receives.
        var dropAcks: Set<Int> = []
        /// The link drops on these OTA writes (1-based); the write fails.
        var disconnectOnWrites: Set<Int> = []
        /// The board restarts (losing the partial image) on these disconnects.
        var rebootOnDisconnect = false
        /// Connect attempts that fail before one succeeds, per disconnect.
        var failedConnectsAfterDrop = 0
        /// Flip a byte as it is written to flash, so OtaEnd fails the SHA check.
        var corruptOffset: Int?
        var writeFailedAtOffset: Int?
        /// The new image does not start: the bootloader returns to the old one.
        var rollBack = false
        /// The board never comes back after the restart.
        var staysOffAfterRestart = false
        /// OtaEnd gets no answer (the board restarts before indicating).
        var silentOtaEnd = false
        /// The new image speaks another protocol major (Hello is incompatible).
        var incompatibleAfterRestart = false
        /// Hellos after the restart that come before the self-test passes, so
        /// they do not confirm the image yet.
        var unconfirmedHellos = 0
        /// The board was power cycled after confirming: the flag is lost.
        var forgetsConfirmation = false
    }

    struct State {
        var connected = true
        var version: String
        var faults = Faults()
        var otaSize = 0
        var otaSHA = Data()
        var received = Data()
        var active = false
        var lastAck = 0
        var outOfOrderSent = false
        var writes = 0
        var acks = 0
        var connects = 0
        var failedConnectsLeft = 0
        var begins: [UInt32] = []  // start_offset answered to each OtaBegin
        var aborts = 0
        var installed: Data?
        var justUpdated = false
        var installedOnce = false
        var hellos = 0
        var maxAhead = 0
        var lastSkipAck: ContinuousClock.Instant?
        var commands: [String] = []
    }

    let board = BoardID(UUID())
    let model: NSBBoardModel
    let chip: NSBChip
    let maxChunk: UInt32
    let window: UInt32
    let state: Mutex<State>
    private let out = Broadcaster<BoardEvent>()

    init(version: String = "0.1.0", model: NSBBoardModel = .esp32C5Devkitc1, chip: NSBChip = .esp32C5, maxChunk: UInt32 = 240, window: UInt32 = 2048) {
        self.model = model
        self.chip = chip
        self.maxChunk = maxChunk
        self.window = window
        state = Mutex(State(version: version))
    }

    func setFaults(_ change: (inout Faults) -> Void) {
        state.withLock { change(&$0.faults) }
    }

    var info: NSBBoardInfo {
        let version = state.withLock(\.version)
        return .with {
            $0.protocolMajor = 1
            $0.firmwareVersion = version
            $0.boardModel = model
            $0.chip = chip
            $0.shortID = "AB12"
            $0.modelName = "ESP32-C5-DevKitC-1"
        }
    }

    // MARK: BoardTransport

    func discoveries() -> AsyncStream<[DiscoveredBoard]> { AsyncStream { $0.finish() } }
    func events() -> AsyncStream<BoardEvent> { out.stream() }
    func startScanning() async {}
    func stopScanning() async {}

    func connect(_ board: BoardID, timeout: Duration?) async throws(BoardTransportError) {
        let result: Result<Void, BoardTransportError> = state.withLock { state in
            if state.connected { return .success(()) }
            state.connects += 1
            if state.faults.staysOffAfterRestart && state.justUpdated { return .failure(.timeout) }
            if state.failedConnectsLeft > 0 {
                state.failedConnectsLeft -= 1
                return .failure(.connectionFailed("not in range"))
            }
            state.connected = true
            return .success(())
        }
        if case .failure(let error) = result {
            try? await Task.sleep(for: .milliseconds(5))
            throw error
        }
        out.send(.connectionState(board, .connected(info)))
    }

    func disconnect(_ board: BoardID) async {
        drop(reason: .requested, reboot: false)
    }

    func readInfo(_ board: BoardID) async throws(BoardTransportError) -> NSBBoardInfo { info }

    func send(_ request: NSBControlRequest, to board: BoardID, timeout: Duration) async throws(BoardTransportError) -> NSBControlResponse {
        guard state.withLock(\.connected) else { throw .notConnected }
        var response = NSBControlResponse()
        response.requestID = request.requestID
        response.result = .ok
        var restartAfter = false
        switch request.command {
        case .hello?:
            let (version, confirmed, compatible) = state.withLock { state in
                state.hellos += 1
                state.commands.append("hello")
                let compatible = !(state.faults.incompatibleAfterRestart && state.installedOnce)
                if state.justUpdated, state.faults.forgetsConfirmation { state.justUpdated = false }
                if state.justUpdated, state.faults.unconfirmedHellos > 0 {
                    state.faults.unconfirmedHellos -= 1
                    return (state.version, false, compatible)
                }
                // Like the firmware: only a compatible Hello confirms and reports it, once.
                defer { if compatible { state.justUpdated = false } }
                return (state.version, state.justUpdated && compatible, compatible)
            }
            response.result = compatible ? .ok : .incompatible
            response.payload = .hello(.with {
                $0.protocolMajor = compatible ? 1 : 2
                $0.compatible = compatible
                $0.firmwareVersion = version
                $0.otaImageConfirmed = confirmed
            })
        case .otaBegin(let begin)?:
            let start: UInt32 = state.withLock { state in
                state.commands.append("begin")
                if !(state.active && state.otaSize == Int(begin.imageSize) && state.otaSHA == begin.sha256) {
                    state.received = Data()
                    state.lastAck = 0
                }
                state.otaSize = Int(begin.imageSize)
                state.otaSHA = begin.sha256
                state.active = true
                state.outOfOrderSent = false
                state.begins.append(UInt32(state.received.count))
                return UInt32(state.received.count)
            }
            response.payload = .otaBegin(.with {
                $0.maxChunkSize = maxChunk
                $0.windowBytes = window
                $0.startOffset = start
            })
        case .otaEnd?:
            let (result, silent) = state.withLock { state -> (NSBResultCode, Bool) in
                state.commands.append("end")
                guard state.active, state.received.count == state.otaSize else { return (.invalidState, false) }
                state.active = false
                guard Data(SHA256.hash(data: state.received)) == state.otaSHA else {
                    state.received = Data()
                    return (.otaVerifyFailed, false)
                }
                state.installed = state.received
                return (.ok, state.faults.silentOtaEnd)
            }
            response.result = result
            restartAfter = result == .ok
            if silent {
                restart()
                throw .timeout
            }
        case .otaAbort?:
            state.withLock { state in
                state.commands.append("abort")
                state.aborts += 1
                state.active = false
                state.received = Data()
            }
        case .ping(let ping)?:
            response.payload = .ping(.with {
                $0.nonce = ping.nonce
                $0.boardTimeMs = 1
            })
        case .setTime?, .stop?:
            break
        default:
            response.result = .unsupported
        }
        if restartAfter {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(20))
                self?.restart()
            }
        }
        return response
    }

    func maximumOTAWriteLength(for board: BoardID) async -> Int? {
        state.withLock(\.connected) ? Int(maxChunk) + 4 : nil
    }

    func writeOTAChunk(_ chunk: Data, to board: BoardID) async throws(BoardTransportError) {
        enum Outcome { case drop, disconnect, acks([NSBOtaAck]) }
        let outcome: Outcome = state.withLock { state in
            guard state.connected else { return .acks([]) }
            state.writes += 1
            if state.faults.disconnectOnWrites.contains(state.writes) { return .disconnect }
            if state.faults.dropWrites.contains(state.writes) { return .drop }
            return .acks(receive(chunk, &state))
        }
        switch outcome {
        case .disconnect:
            let reboot = state.withLock(\.faults.rebootOnDisconnect)
            drop(reason: .linkLost, reboot: reboot)
            throw .notConnected
        case .drop:
            return
        case .acks(let acks):
            guard state.withLock(\.connected) else { throw .notConnected }
            for ack in acks {
                let delivered = state.withLock { state in
                    state.acks += 1
                    return !state.faults.dropAcks.contains(state.acks)
                }
                if delivered { out.send(.otaAck(board, ack)) }
            }
        }
    }

    func connectionStates() async -> [BoardID: BoardConnectionState] {
        [board: state.withLock(\.connected) ? .connected(info) : .disconnected(.linkLost)]
    }

    func knownBoards() async -> [KnownBoard] { [] }
    func forgetKnownBoard(_ board: BoardID) async {}

    // MARK: Board behaviour

    private func receive(_ chunk: Data, _ state: inout State) -> [NSBOtaAck] {
        var offset = chunk.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        var bytes = chunk.dropFirst(4)
        state.maxAhead = max(state.maxAhead, offset + bytes.count - state.lastAck)
        guard state.active else { return [ack(.notActive, state.received.count)] }
        let next = state.received.count
        if offset < next {
            if offset + bytes.count == next { return [ack(.ok, next)] }
            if offset + bytes.count < next {
                let now = ContinuousClock.now
                if let last = state.lastSkipAck, now - last < .seconds(1) { return [] }
                state.lastSkipAck = now
                return [ack(.ok, next)]
            }
            bytes = bytes.dropFirst(next - offset)  // Runs past next_offset: keep the new part.
            offset = next
        }
        if offset > next {
            guard !state.outOfOrderSent else { return [] }
            state.outOfOrderSent = true
            return [ack(.outOfOrder, next)]
        }
        guard offset + bytes.count <= state.otaSize else {
            state.active = false
            return [ack(.overflow, next)]
        }
        if let bad = state.faults.writeFailedAtOffset, (offset..<(offset + bytes.count)).contains(bad) {
            state.active = false
            return [ack(.writeFailed, next)]
        }
        state.outOfOrderSent = false
        var written = Data(bytes)
        if let corrupt = state.faults.corruptOffset, (offset..<(offset + written.count)).contains(corrupt) {
            written[written.startIndex + corrupt - offset] ^= 0xFF
        }
        state.received.append(written)
        let now = state.received.count
        if now == state.otaSize || now - state.lastAck >= Int(window) / 2 {
            state.lastAck = now
            return [ack(.ok, now)]
        }
        return []
    }

    private func ack(_ status: NSBOtaAckStatus, _ next: Int) -> NSBOtaAck {
        .with {
            $0.status = status
            $0.nextOffset = UInt32(next)
        }
    }

    private func drop(reason: BoardDisconnectReason, reboot: Bool) {
        let wasConnected = state.withLock { state in
            let was = state.connected
            state.connected = false
            state.failedConnectsLeft = state.faults.failedConnectsAfterDrop
            if reboot {
                state.active = false
                state.received = Data()
                state.lastAck = 0
            }
            return was
        }
        if wasConnected { out.send(.connectionState(board, .disconnected(reason))) }
    }

    /// Restarts into the installed image (or the old one when rolling back).
    private func restart() {
        state.withLock { state in
            if let image = state.installed, !state.faults.rollBack {
                state.version = EspAppImage(image)?.version ?? "unknown"
                state.justUpdated = true
                state.installedOnce = true
            }
            state.installed = nil
        }
        drop(reason: .linkLost, reboot: true)
    }
}
