import BoardProtocol
import Foundation
import Synchronization
import Testing
@testable import BoardKit

/// Records begin/end calls, like the BoardManager would see them.
final class RecordingCoordinator: FirmwareUpdateCoordinator, Sendable {
    let calls = Mutex<[String]>([])
    let refuse: Bool

    init(refuse: Bool = false) {
        self.refuse = refuse
    }

    func beginFirmwareUpdate(_ board: BoardID) async throws {
        calls.withLock { $0.append("begin") }
        if refuse { throw FirmwareUpdateError.surveyRunning }
    }

    func endFirmwareUpdate(_ board: BoardID) async {
        calls.withLock { $0.append("end") }
    }
}

final class PhaseLog: Sendable {
    let phases = Mutex<[FirmwareInstallPhase]>([])

    func record(_ phase: FirmwareInstallPhase) {
        phases.withLock { $0.append(phase) }
    }

    var reconnects: Int {
        phases.withLock { $0.filter { if case .reconnecting = $0 { true } else { false } }.count }
    }

    var lastSent: Int? {
        phases.withLock { list in
            list.compactMap { if case .transferring(let sent, _) = $0 { sent } else { nil } }.last
        }
    }
}

@Suite("Firmware installer (OTA state machine)", .timeLimit(.minutes(1)))
struct FirmwareInstallerTests {
    static let size = 20_000

    static func package(version: String = "0.2.0", size: Int = size) -> FirmwarePackage {
        try! FirmwarePackage.file(FirmwareReleaseFixture.image(chipID: 0x17, version: version, size: size), signature: nil, trust: .development)
    }

    static var timing: FirmwareInstaller.Timing {
        var timing = FirmwareInstaller.Timing()
        timing.connectAttempt = .milliseconds(200)
        timing.reconnectBudget = .seconds(2)
        timing.retryDelay = .milliseconds(10)
        timing.restartWait = .milliseconds(500)
        timing.returnBudget = .seconds(2)
        timing.ackTimeout = .milliseconds(100)
        timing.confirmWait = .milliseconds(300)
        timing.confirmRetry = .milliseconds(20)
        return timing
    }

    func install(
        _ board: MockOtaBoard, package: FirmwarePackage = package(), coordinator: (any FirmwareUpdateCoordinator & Sendable)? = nil,
        log: PhaseLog = PhaseLog()
    ) async throws(FirmwareUpdateError) -> FirmwareInstallResult {
        let installer = FirmwareInstaller(
            transport: board, board: board.board, package: package, appVersion: "test", coordinator: coordinator, timing: Self.timing
        )
        return try await installer.run { log.record($0) }
    }

    @Test func installsAndConfirmsTheNewVersion() async throws {
        let board = MockOtaBoard()
        let coordinator = RecordingCoordinator()
        let log = PhaseLog()
        let result = try await install(board, coordinator: coordinator, log: log)
        #expect(result == FirmwareInstallResult(
            previousVersion: "0.1.0", newVersion: "0.2.0", imageConfirmed: true, compatible: true, interruptions: 0
        ))
        #expect(coordinator.calls.withLock { $0 } == ["begin", "end"])
        let state = board.state.withLock { $0 }
        #expect(state.commands == ["begin", "end", "hello"])
        #expect(state.maxAhead <= Int(board.window))
        #expect(log.lastSent == Self.size)
        let phases = log.phases.withLock { $0 }
        #expect(phases.first == .connecting)
        #expect(Array(phases.suffix(3)) == [.verifying, .restarting, .confirming])
    }

    @Test func lostAckIsRecoveredWithoutRestarting() async throws {
        let board = MockOtaBoard()
        board.setFaults { $0.dropAcks = [2, 5] }
        let result = try await install(board)
        #expect(result.newVersion == "0.2.0")
        #expect(result.interruptions == 0)
        #expect(board.state.withLock(\.begins) == [0])
    }

    @Test func lostChunkIsResentAfterOutOfOrder() async throws {
        let board = MockOtaBoard()
        board.setFaults { $0.dropWrites = [3, 40] }
        let result = try await install(board)
        #expect(result.newVersion == "0.2.0")
        #expect(board.state.withLock(\.begins) == [0])
    }

    @Test func disconnectMidTransferResumesFromTheBoardsOffset() async throws {
        let board = MockOtaBoard()
        board.setFaults {
            $0.disconnectOnWrites = [30]
            $0.failedConnectsAfterDrop = 2
        }
        let log = PhaseLog()
        let result = try await install(board, log: log)
        #expect(result.newVersion == "0.2.0")
        #expect(result.interruptions == 1)
        #expect(log.reconnects == 1)
        let begins = board.state.withLock(\.begins)
        #expect(begins.count == 2)
        #expect(begins[0] == 0)
        #expect(begins[1] > 0)  // Resumed, not restarted.
        #expect(Int(begins[1]) < Self.size)
    }

    @Test func boardRestartDuringTransferStartsOverFromZero() async throws {
        let board = MockOtaBoard()
        board.setFaults {
            $0.disconnectOnWrites = [30]
            $0.rebootOnDisconnect = true
        }
        let result = try await install(board)
        #expect(result.newVersion == "0.2.0")
        #expect(board.state.withLock(\.begins) == [0, 0])
    }

    @Test func givesUpAfterTooManyInterruptions() async throws {
        let board = MockOtaBoard()
        board.setFaults { $0.disconnectOnWrites = Set(stride(from: 5, to: 400, by: 5)) }
        let coordinator = RecordingCoordinator()
        await #expect(throws: FirmwareUpdateError.connectionLost) {
            try await install(board, coordinator: coordinator)
        }
        #expect(coordinator.calls.withLock { $0 } == ["begin", "end"])
        #expect(board.state.withLock(\.begins).count == Self.timing.maxInterruptions + 1)
        #expect(board.state.withLock(\.aborts) == 0)  // Partial image kept for a later resume.
    }

    @Test func boardOutOfReachDuringTransfer() async throws {
        let board = MockOtaBoard()
        board.setFaults {
            $0.disconnectOnWrites = [10]
            $0.failedConnectsAfterDrop = 10_000
        }
        await #expect(throws: FirmwareUpdateError.connectionLost) { try await install(board) }
    }

    @Test func shaMismatchReportedByTheBoard() async throws {
        let board = MockOtaBoard()
        board.setFaults { $0.corruptOffset = 12_345 }
        await #expect(throws: FirmwareUpdateError.verifyFailed) { try await install(board) }
        let state = board.state.withLock { $0 }
        #expect(state.version == "0.1.0")
        #expect(state.connected)
        #expect(state.hellos == 0)
    }

    @Test func flashWriteFailure() async throws {
        let board = MockOtaBoard()
        board.setFaults { $0.writeFailedAtOffset = 5_000 }
        await #expect(throws: FirmwareUpdateError.flashWriteFailed) { try await install(board) }
    }

    @Test func rollbackIsReported() async throws {
        let board = MockOtaBoard()
        board.setFaults { $0.rollBack = true }
        await #expect(throws: FirmwareUpdateError.rolledBack(version: "0.1.0")) { try await install(board) }
    }

    @Test func boardThatNeverReturns() async throws {
        let board = MockOtaBoard()
        board.setFaults { $0.staysOffAfterRestart = true }
        await #expect(throws: FirmwareUpdateError.boardDidNotReturn) { try await install(board) }
    }

    @Test func unansweredOtaEndStillConfirmsByHello() async throws {
        let board = MockOtaBoard()
        board.setFaults { $0.silentOtaEnd = true }
        let result = try await install(board)
        #expect(result.newVersion == "0.2.0")
    }

    @Test func wrongChipIsRefusedBeforeOtaBegin() async throws {
        let board = MockOtaBoard(model: .esp32C3Generic, chip: .esp32C3)
        await #expect(throws: FirmwareUpdateError.wrongChip(board: "ESP32-C3", image: "ESP32-C5")) { try await install(board) }
        #expect(board.state.withLock(\.commands).isEmpty)
    }

    @Test func coordinatorRefusalStopsBeforeTouchingTheBoard() async throws {
        let board = MockOtaBoard()
        let coordinator = RecordingCoordinator(refuse: true)
        await #expect(throws: FirmwareUpdateError.surveyRunning) { try await install(board, coordinator: coordinator) }
        #expect(board.state.withLock(\.commands).isEmpty)
    }

    @Test func notConnectedAndUnreachable() async throws {
        let board = MockOtaBoard()
        await board.disconnect(board.board)
        board.setFaults { $0.failedConnectsAfterDrop = 10_000 }
        await board.disconnect(board.board)
        board.state.withLock { $0.failedConnectsLeft = 10_000 }
        await #expect(throws: FirmwareUpdateError.notConnected) { try await install(board) }
    }

    @Test func cancelSendsOtaAbort() async throws {
        let board = MockOtaBoard()
        // Lose every ack after the first so the transfer hangs in resends.
        board.setFaults { $0.dropAcks = Set(2...10_000) }
        let installer = FirmwareInstaller(
            transport: board, board: board.board, package: Self.package(), appVersion: "test", timing: Self.timing
        )
        let task = Task { try await installer.run() }
        #expect(await eventually { board.state.withLock(\.acks) >= 2 })
        task.cancel()
        let result = await task.result
        #expect(throws: FirmwareUpdateError.cancelled) { try result.get() }
        #expect(board.state.withLock(\.aborts) == 1)
        #expect(board.state.withLock(\.version) == "0.1.0")
    }

    @Test func unsignedDIYImageWithoutVersionInstalls() async throws {
        var image = FirmwareReleaseFixture.image(chipID: 0x17, version: "", size: 9_000)
        image[32] = 0  // No app description: no version to expect.
        let package = try FirmwarePackage.file(image, signature: nil, trust: FirmwareTrust(keys: []))
        #expect(package.origin == .unsignedFile)
        #expect(package.version == nil)
        let board = MockOtaBoard()
        let result = try await install(board, package: package)
        #expect(result.newVersion == "unknown")  // Whatever the board reports.
    }

    @Test func reinstallOfTheSameVersionNeedsTheBoardsConfirmation() async throws {
        // The version alone cannot tell a rollback from a successful reinstall.
        let board = MockOtaBoard(version: "0.2.0")
        board.setFaults { $0.rollBack = true }
        await #expect(throws: FirmwareUpdateError.notConfirmed(version: "0.2.0")) { try await install(board) }

        let healthy = MockOtaBoard(version: "0.2.0")
        let result = try await install(healthy)
        #expect(result.imageConfirmed)
        #expect(result.newVersion == "0.2.0")
    }

    @Test func confirmationOnALaterHelloIsAwaited() async throws {
        // The self-test had not passed yet on the first Hello after the restart.
        let board = MockOtaBoard(version: "0.2.0")
        board.setFaults { $0.unconfirmedHellos = 2 }
        // Three reconnects and Hellos can outlast the usual 300 ms on a busy CI
        // runner; the test still ends as soon as the third Hello confirms.
        var timing = Self.timing
        timing.confirmWait = .seconds(10)
        let installer = FirmwareInstaller(
            transport: board, board: board.board, package: Self.package(), appVersion: "test", timing: timing
        )
        let result = try await installer.run()
        #expect(result.imageConfirmed)
        #expect(board.state.withLock(\.hellos) == 3)
    }

    @Test func newVersionCountsEvenWhenTheConfirmationWasLost() async throws {
        // Power cycled after the self-test confirmed: the flag is gone, the version decides.
        let board = MockOtaBoard()
        board.setFaults { $0.forgetsConfirmation = true }
        let result = try await install(board)
        #expect(result.newVersion == "0.2.0")
        #expect(!result.imageConfirmed)
        #expect(board.state.withLock(\.hellos) == 1)
    }

    @Test func imageWithoutVersionThatRollsBackIsReported() async throws {
        var image = FirmwareReleaseFixture.image(chipID: 0x17, size: 9_000)
        image[32] = 0
        let package = try FirmwarePackage.file(image, signature: nil, trust: FirmwareTrust(keys: []))
        let board = MockOtaBoard()
        board.setFaults { $0.rollBack = true }
        await #expect(throws: FirmwareUpdateError.notConfirmed(version: "0.1.0")) { try await install(board, package: package) }
    }

    @Test func newImageOfAnotherProtocolMajorIsJudgedByVersion() async throws {
        let board = MockOtaBoard()
        board.setFaults { $0.incompatibleAfterRestart = true }
        let result = try await install(board)
        #expect(result.newVersion == "0.2.0")
        #expect(!result.compatible)
        #expect(!result.imageConfirmed)
    }

    @Test func restartChecks() throws {
        func hello(_ version: String, confirmed: Bool, compatible: Bool = true) -> NSBHelloResult {
            .with {
                $0.firmwareVersion = version
                $0.otaImageConfirmed = confirmed
                $0.compatible = compatible
            }
        }
        typealias I = FirmwareInstaller
        // A new version: the version decides, the flag does not matter.
        #expect(try I.checkRestart(hello("0.2.0", confirmed: false), expected: "0.2.0", previous: "0.1.0", endConfirmed: true) == .installed)
        #expect(throws: FirmwareUpdateError.rolledBack(version: "0.1.0")) {
            try I.checkRestart(hello("0.1.0", confirmed: true), expected: "0.2.0", previous: "0.1.0", endConfirmed: true)
        }
        #expect(throws: FirmwareUpdateError.connectionLost) {
            try I.checkRestart(hello("0.1.0", confirmed: false), expected: "0.2.0", previous: "0.1.0", endConfirmed: false)
        }
        #expect(throws: FirmwareUpdateError.unexpectedVersion(expected: "0.2.0", found: "0.3.0")) {
            try I.checkRestart(hello("0.3.0", confirmed: true), expected: "0.2.0", previous: "0.1.0", endConfirmed: true)
        }
        #expect(throws: FirmwareUpdateError.rolledBack(version: "0.1.0")) {
            try I.checkRestart(hello("0.1.0", confirmed: false, compatible: false), expected: "0.2.0", previous: "0.1.0", endConfirmed: true)
        }
        // Same version or no version: only the confirmation can tell.
        #expect(try I.checkRestart(hello("0.1.0", confirmed: true), expected: "0.1.0", previous: "0.1.0", endConfirmed: true) == .installed)
        #expect(try I.checkRestart(hello("0.1.0", confirmed: false), expected: "0.1.0", previous: "0.1.0", endConfirmed: true) == .awaitingConfirmation)
        #expect(try I.checkRestart(hello("x", confirmed: false), expected: nil, previous: "0.1.0", endConfirmed: true) == .awaitingConfirmation)
        #expect(try I.checkRestart(hello("9.0.0", confirmed: false, compatible: false), expected: nil, previous: "0.1.0", endConfirmed: true) == .installed)
    }

    @Test func cancelAfterOtaEndDoesNotAbort() async throws {
        let board = MockOtaBoard()
        board.setFaults { $0.staysOffAfterRestart = true }
        let log = PhaseLog()
        let installer = FirmwareInstaller(
            transport: board, board: board.board, package: Self.package(), appVersion: "test", timing: Self.timing
        )
        let task = Task { try await installer.run { log.record($0) } }
        #expect(await eventually { log.phases.withLock { $0.contains(.restarting) } })
        task.cancel()
        let result = await task.result
        #expect(throws: FirmwareUpdateError.cancelled) { try result.get() }
        #expect(board.state.withLock(\.aborts) == 0)
    }

    @Test func oversizedPackageIsRefused() async throws {
        let board = MockOtaBoard()
        let image = FirmwareReleaseFixture.image(chipID: 0x17, size: FirmwareLimits.maxImageBytes + 1)
        let package = FirmwarePackage(
            image: image, sha256: Data(count: 32), version: nil, origin: .unsignedFile, header: EspAppImage(image)!
        )
        await #expect(throws: FirmwareUpdateError.imageTooLarge) { try await install(board, package: package) }
        #expect(board.state.withLock(\.commands).isEmpty)
    }

    // MARK: With the board manager

    @MainActor @Test func managerHandsTheBoardOverAndTakesItBack() async throws {
        let board = MockOtaBoard()
        let manager = BoardManager(transport: board, appVersion: "test")
        try await manager.connect(board.board)
        #expect(manager.boards[board.board]?.isReady == true)

        let installer = FirmwareInstaller(
            transport: board, board: board.board, package: Self.package(), appVersion: "test", coordinator: manager,
            timing: Self.timing
        )
        let result = try await installer.run()
        #expect(result.newVersion == "0.2.0")
        // The manager reconnects on its own after the update and sees the new firmware.
        #expect(await eventually { manager.boards[board.board]?.isReady == true })
        #expect(manager.boards[board.board]?.compatibility == .compatible(firmwareVersion: "0.2.0"))
        #expect(manager.boards[board.board]?.isUpdating == false)
        // Manager Hello, installer Hello after the restart, manager Hello when it takes the board back.
        #expect(board.state.withLock(\.hellos) == 3)
    }

    @MainActor @Test func managerRefusesAnUpdateDuringASurvey() async throws {
        let board = MockOtaBoard()
        let manager = BoardManager(transport: board, appVersion: "test")
        try await manager.connect(board.board)
        manager.capture = SurveyCapture()
        let installer = FirmwareInstaller(
            transport: board, board: board.board, package: Self.package(), appVersion: "test", coordinator: manager,
            timing: Self.timing
        )
        await #expect(throws: FirmwareUpdateError.surveyRunning) { try await installer.run() }
        #expect(!board.state.withLock(\.commands).contains("begin"))
        manager.capture = nil
    }

    @MainActor @Test func managerDoesNotReconnectTheBoardDuringTheUpdate() async throws {
        let board = MockOtaBoard()
        let manager = BoardManager(transport: board, appVersion: "test", reconnectPolicy: .standard)
        try await manager.connect(board.board)
        board.setFaults {
            $0.disconnectOnWrites = [20]
            $0.failedConnectsAfterDrop = 3
        }
        let installer = FirmwareInstaller(
            transport: board, board: board.board, package: Self.package(), appVersion: "test", coordinator: manager,
            timing: Self.timing
        )
        let result = try await installer.run()
        #expect(result.interruptions == 1)
        #expect(await eventually { manager.boards[board.board]?.isReady == true })
        // No manager Hello between the drop and the resumed OtaBegin.
        #expect(board.state.withLock(\.commands) == ["hello", "begin", "begin", "end", "hello", "hello"])
    }
}
