import BoardProtocol
import Foundation

/// Lets a firmware update drive a board directly over the transport. While an
/// update runs the coordinator (the `BoardManager`) must not reconnect, adopt,
/// handshake or plan the board.
public protocol FirmwareUpdateCoordinator {
    /// Throws when the board cannot be updated now (for example a survey runs).
    func beginFirmwareUpdate(_ board: BoardID) async throws
    /// Hands the board back for normal use (Hello again, survey planning).
    func endFirmwareUpdate(_ board: BoardID) async
}

/// The manager stops reconnecting, adopting and planning the board while the
/// update runs (BoardManager+FirmwareUpdate.swift).
extension BoardManager: FirmwareUpdateCoordinator {}

public enum FirmwareInstallPhase: Sendable, Equatable {
    case connecting
    case transferring(sent: Int, total: Int)
    /// The link dropped during the transfer; reconnecting to resume.
    case reconnecting(attempt: Int)
    /// OtaEnd sent: the board checks the SHA-256 and the image.
    case verifying
    /// The board restarts into the new image; waiting for it to come back.
    case restarting
    /// Reconnected: Hello reports the running version.
    case confirming
}

public struct FirmwareInstallResult: Sendable, Equatable {
    public var previousVersion: String
    public var newVersion: String
    /// The board confirmed the new image on this Hello (protocol.md section 10, step 5).
    public var imageConfirmed: Bool
    /// The new firmware speaks this app's protocol major.
    public var compatible: Bool
    /// Times the transfer was interrupted and resumed.
    public var interruptions: Int
}

/// Installs a verified firmware package on one board (protocol.md section 10):
/// OtaBegin, the chunk transfer with ack windowing, OtaEnd, then waits for the
/// restart, reconnects and checks the version with Hello.
///
/// A dropped link, a stalled transfer or a board that lost the transfer state
/// is resumed by reconnecting and sending the same OtaBegin again; the board
/// answers with the offset to continue from. Cancelling the task sends OtaAbort.
public actor FirmwareInstaller {
    public struct Timing: Sendable {
        public var connectAttempt: Duration = .seconds(10)
        /// How long to try to reconnect after one interruption.
        public var reconnectBudget: Duration = .seconds(60)
        public var retryDelay: Duration = .seconds(1)
        /// Wait for the link to drop after OtaEnd before forcing a new connection.
        public var restartWait: Duration = .seconds(15)
        /// How long the board may take to restart and reconnect.
        public var returnBudget: Duration = .seconds(90)
        public var ackTimeout: Duration = .seconds(5)
        public var maxInterruptions = 5
        /// When only the board's confirmation can tell success from a rollback
        /// (same version reinstalled, image without a version): how long to
        /// keep saying Hello, and how often. The board confirms on a Hello once
        /// its self-test passes, which can take a moment after the restart.
        public var confirmWait: Duration = .seconds(20)
        public var confirmRetry: Duration = .seconds(2)

        public init() {}
    }

    public nonisolated let transport: any BoardTransport
    public nonisolated let board: BoardID
    public nonisolated let package: FirmwarePackage
    public nonisolated let appVersion: String
    public nonisolated let timing: Timing
    nonisolated let coordinator: (any FirmwareUpdateCoordinator & Sendable)?

    private var nextRequestID = UInt32.random(in: 0x1000_0000...0x7FFF_0000)
    private var interruptions = 0
    private var transferStarted = false

    public init(
        transport: any BoardTransport, board: BoardID, package: FirmwarePackage, appVersion: String,
        coordinator: (any FirmwareUpdateCoordinator & Sendable)? = nil, timing: Timing = Timing()
    ) {
        self.transport = transport
        self.board = board
        self.package = package
        self.appVersion = appVersion
        self.coordinator = coordinator
        self.timing = timing
    }

    public func run(
        onPhase: @escaping @Sendable (FirmwareInstallPhase) -> Void = { _ in }
    ) async throws(FirmwareUpdateError) -> FirmwareInstallResult {
        if let coordinator {
            do {
                try await coordinator.beginFirmwareUpdate(board)
            } catch let error as FirmwareUpdateError {
                throw error
            } catch BoardManagerError.surveyRunning {
                throw .surveyRunning
            } catch {
                throw .boardBusy
            }
        }
        let outcome: Result<FirmwareInstallResult, FirmwareUpdateError>
        do {
            outcome = .success(try await install(onPhase))
        } catch {
            let failure = Self.classify(error)
            if failure == .cancelled || Task.isCancelled, transferStarted {
                // A new task: the cancelled one could not send OtaAbort.
                await Task { await self.abortTransfer() }.value
            }
            outcome = .failure(Task.isCancelled ? .cancelled : failure)
        }
        await coordinator?.endFirmwareUpdate(board)
        return try outcome.get()
    }

    // MARK: - Steps

    private func install(_ onPhase: @escaping @Sendable (FirmwareInstallPhase) -> Void) async throws -> FirmwareInstallResult {
        guard package.image.count <= min(FirmwareLimits.maxImageBytes, Int(UInt32.max)) else {
            throw FirmwareUpdateError.imageTooLarge
        }
        onPhase(.connecting)
        let info: NSBBoardInfo
        do {
            info = try await reconnect(budget: timing.connectAttempt)
        } catch FirmwareUpdateError.connectionLost {
            throw FirmwareUpdateError.notConnected
        }
        try package.checkCompatible(with: info)
        let previous = info.firmwareVersion

        var endConfirmed = false
        var events: AsyncStream<BoardEvent>
        while true {
            try await transfer(onPhase)
            onPhase(.verifying)
            events = transport.events()  // Before OtaEnd, so the restart's disconnect is not missed.
            // From here the board may switch images: a cancel must not send OtaAbort.
            transferStarted = false
            switch try await end() {
            case .ok:
                endConfirmed = true
            case .incomplete:
                transferStarted = true
                try await interrupted(onPhase)
                continue
            case .noAnswer:
                endConfirmed = false
            }
            break
        }

        onPhase(.restarting)
        try await waitForRestart(events)
        onPhase(.confirming)
        let hello = try await confirmedHello(previous: previous, endConfirmed: endConfirmed)
        let found = hello.firmwareVersion
        return FirmwareInstallResult(
            previousVersion: previous, newVersion: found, imageConfirmed: hello.otaImageConfirmed,
            compatible: hello.compatible, interruptions: interruptions
        )
    }

    enum RestartVerdict: Equatable {
        case installed
        /// Only `ota_image_confirmed` can decide, and it has not come yet.
        case awaitingConfirmation
    }

    /// Judges the board after the restart (protocol.md section 10, step 5).
    /// The version decides when the package has one that differs from the
    /// previous: the same version means the board returned to its old image,
    /// even with a successful OtaEnd. `ota_image_confirmed` is only used when
    /// the version cannot tell (same version reinstalled, image without a
    /// version), because the board keeps it in memory only and a power cycle
    /// after confirming loses it.
    static func checkRestart(
        _ hello: NSBHelloResult, expected: String?, previous: String, endConfirmed: Bool
    ) throws(FirmwareUpdateError) -> RestartVerdict {
        let found = hello.firmwareVersion
        if let expected, expected != previous {
            if found == expected { return .installed }
            if found == previous { throw endConfirmed ? .rolledBack(version: found) : .connectionLost }
            throw .unexpectedVersion(expected: expected, found: found)
        }
        if let expected, found != expected { throw .unexpectedVersion(expected: expected, found: found) }
        // Only a compatible Hello carries the confirmation; an image of another
        // protocol major cannot be checked further.
        guard hello.compatible, !hello.otaImageConfirmed else { return .installed }
        return .awaitingConfirmation
    }

    /// Reconnects after the restart and says Hello, repeating it for a while
    /// when only the board's confirmation can show that the new image runs.
    private func confirmedHello(previous: String, endConfirmed: Bool) async throws -> NSBHelloResult {
        let clock = ContinuousClock()
        let deadline = clock.now + timing.confirmWait
        while true {
            let hello = try await helloAfterRestart()
            switch try Self.checkRestart(hello, expected: package.version, previous: previous, endConfirmed: endConfirmed) {
            case .installed:
                return hello
            case .awaitingConfirmation:
                guard clock.now + timing.confirmRetry <= deadline else {
                    throw endConfirmed ? FirmwareUpdateError.notConfirmed(version: hello.firmwareVersion) : .connectionLost
                }
                try await Task.sleep(for: timing.confirmRetry)
            }
        }
    }

    /// OtaBegin and the chunk transfer, resuming after interruptions.
    private func transfer(_ onPhase: @escaping @Sendable (FirmwareInstallPhase) -> Void) async throws {
        let total = package.image.count
        while true {
            try Task.checkCancellation()
            let response = try await send(.otaBegin(.with {
                $0.imageSize = UInt32(total)
                $0.sha256 = package.sha256
            }))
            let parameters: NSBOtaBeginResult
            switch response.result {
            case .ok:
                guard case .otaBegin(let result)? = response.payload else {
                    throw FirmwareUpdateError.protocolError("OtaBegin without parameters")
                }
                parameters = result
            case .invalidArgument: throw FirmwareUpdateError.imageTooLarge
            case .busy: throw FirmwareUpdateError.boardBusy
            default: throw FirmwareUpdateError.boardRejected(Self.describe(response))
            }
            transferStarted = true
            onPhase(.transferring(sent: Int(parameters.startOffset), total: total))

            var sender = OtaChunkSender(transport: transport, board: board, image: package.image, parameters: parameters)
            sender.ackTimeout = timing.ackTimeout
            do {
                try await sender.run { onPhase(.transferring(sent: $0, total: total)) }
                return
            } catch {
                try Task.checkCancellation()
                switch error {
                case .transport(let transportError) where !Self.needsUser(transportError):
                    break
                case .stalled, .boardAborted(.notActive):
                    break
                case .transport(let transportError):
                    throw transportError
                case .boardAborted(.writeFailed):
                    throw FirmwareUpdateError.flashWriteFailed
                case .boardAborted(let status):
                    throw FirmwareUpdateError.protocolError("board ended the transfer: \(status)")
                case .badParameters(let detail):
                    throw FirmwareUpdateError.protocolError(detail)
                }
            }
            try await interrupted(onPhase)
        }
    }

    private enum EndOutcome { case ok, incomplete, noAnswer }

    private func end() async throws -> EndOutcome {
        let response: NSBControlResponse
        do {
            response = try await send(.otaEnd(NSBOtaEnd()), timeout: ControlTimeout.otaEnd)
        } catch let error as BoardTransportError where !Self.needsUser(error) && error != .cancelled {
            return .noAnswer  // The board may already be restarting; Hello decides.
        }
        switch response.result {
        case .ok: return .ok
        case .otaVerifyFailed: throw FirmwareUpdateError.verifyFailed
        case .invalidState: return .incomplete  // The board lost part of the image (it restarted).
        default: throw FirmwareUpdateError.boardRejected(Self.describe(response))
        }
    }

    /// Counts an interruption and reconnects if needed.
    private func interrupted(_ onPhase: @escaping @Sendable (FirmwareInstallPhase) -> Void) async throws {
        interruptions += 1
        guard interruptions <= timing.maxInterruptions else { throw FirmwareUpdateError.connectionLost }
        onPhase(.reconnecting(attempt: interruptions))
        _ = try await reconnect(budget: timing.reconnectBudget)
    }

    /// Waits for the board to drop the link after OtaEnd (it restarts about a
    /// second later), then forces a fresh link if it never dropped.
    private func waitForRestart(_ events: AsyncStream<BoardEvent>) async throws {
        guard await transport.connectionStates()[board]?.isConnected == true else { return }
        let dropped = await Self.firstDisconnect(of: board, in: events, within: timing.restartWait)
        try Task.checkCancellation()
        if !dropped, await transport.connectionStates()[board]?.isConnected == true {
            await transport.disconnect(board)
        }
    }

    private func helloAfterRestart() async throws -> NSBHelloResult {
        do {
            _ = try await reconnect(budget: timing.returnBudget)
        } catch let error as FirmwareUpdateError where error == .connectionLost || error == .notConnected {
            throw FirmwareUpdateError.boardDidNotReturn
        }
        let response: NSBControlResponse
        do {
            response = try await send(.hello(.current(appVersion: appVersion)))
        } catch let error as BoardTransportError where !Self.needsUser(error) {
            throw FirmwareUpdateError.boardDidNotReturn
        }
        guard response.result == .ok || response.result == .incompatible, case .hello(let hello)? = response.payload else {
            throw FirmwareUpdateError.protocolError("Hello: \(Self.describe(response))")
        }
        return hello
    }

    private func abortTransfer() async {
        guard await transport.connectionStates()[board]?.isConnected == true else { return }
        _ = try? await send(.otaAbort(NSBOtaAbort()))
    }

    // MARK: - Helpers

    /// Connects if needed, retrying until `budget` runs out; returns the board's Info.
    private func reconnect(budget: Duration) async throws -> NSBBoardInfo {
        let clock = ContinuousClock()
        let deadline = clock.now + budget
        while true {
            try Task.checkCancellation()
            if case .connected(let info)? = await transport.connectionStates()[board] { return info }
            let remaining = deadline - clock.now
            guard remaining > .zero else { throw FirmwareUpdateError.connectionLost }
            do {
                try await transport.connect(board, timeout: min(timing.connectAttempt, remaining))
            } catch {
                if Self.needsUser(error) { throw error }
                try await Task.sleep(for: min(timing.retryDelay, max(deadline - clock.now, .zero)))
            }
        }
    }

    private func send(_ command: NSBControlRequest.OneOf_Command, timeout: Duration? = nil) async throws -> NSBControlResponse {
        var request = NSBControlRequest()
        request.requestID = nextRequestID
        nextRequestID &+= 1
        request.command = command
        return try await transport.send(request, to: board, timeout: timeout ?? ControlTimeout.for(request))
    }

    private static func firstDisconnect(of board: BoardID, in events: AsyncStream<BoardEvent>, within limit: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await event in events {
                    if case .connectionState(board, let state) = event, state.isDisconnected { return true }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    static func needsUser(_ error: BoardTransportError) -> Bool {
        switch error {
        case .bondMissing, .pairingRejected, .bluetoothUnavailable, .unknownBoard: true
        default: false
        }
    }

    static func describe(_ response: NSBControlResponse) -> String {
        response.message.isEmpty ? "\(response.result)" : "\(response.result): \(response.message)"
    }

    static func classify(_ error: any Error) -> FirmwareUpdateError {
        switch error {
        case let error as FirmwareUpdateError: error
        case let error as BoardTransportError: .from(error)
        case is CancellationError: .cancelled
        default: .protocolError(String(describing: error))
        }
    }
}
