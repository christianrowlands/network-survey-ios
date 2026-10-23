import BoardKit
import BoardProtocol
import Foundation

/// What a session needs to know about the boards beyond their records.
public enum SurveyBoardEvent: Sendable, Equatable {
    /// A board in use dropped; it keeps surveying into its buffer.
    case gapStarted(BoardID, at: Date)
    /// The gap closed. `resumed` is false when the board was given up.
    case gapEnded(BoardID, at: Date, resumed: Bool)
    /// Records the board threw away (ring buffer full), new since the last report.
    case boardDrops(BoardID, records: Int, at: Date)
    case status(BoardID, NSBBoardStatus, receivedAt: Date)
}

/// What a session needs from the boards. `BoardManagerSource` adapts
/// BoardKit's `BoardManager`; tests can supply their own.
public protocol SurveyBoardSource: Sendable {
    /// Boards that finished Hello and SetTime and take commands.
    func readyBoards() async -> [BoardID]
    /// Records from every board. Subscribe before `startSurvey`.
    func records() -> AsyncStream<BoardRecordEnvelope>
    func rawFrames() -> AsyncStream<BoardRawFrameEnvelope>
    func events() -> AsyncStream<SurveyBoardEvent>
    /// Splits channels across the ready boards and starts them. The board
    /// layer re-plans by itself when boards join, rejoin or drop.
    func startSurvey(_ plan: SurveyPlan) async throws
    func stopSurvey() async
}

/// Drives the boards through `BoardManager`.
public struct BoardManagerSource: SurveyBoardSource {
    public let manager: BoardManager

    public init(manager: BoardManager) {
        self.manager = manager
    }

    public func readyBoards() async -> [BoardID] {
        await manager.readyBoards
    }

    public func records() -> AsyncStream<BoardRecordEnvelope> {
        manager.records()
    }

    public func rawFrames() -> AsyncStream<BoardRawFrameEnvelope> {
        manager.rawFrames()
    }

    public func events() -> AsyncStream<SurveyBoardEvent> {
        let events = manager.events()
        return AsyncStream { continuation in
            let task = Task {
                for await event in events {
                    switch event {
                    case .linkGapStarted(let id, let at):
                        continuation.yield(.gapStarted(id, at: at))
                    case .linkGapEnded(let id, _, let resumed):
                        continuation.yield(.gapEnded(id, at: Date(), resumed: resumed))
                    case .drops(let id, let drops) where drops.records > 0:
                        continuation.yield(.boardDrops(id, records: drops.records, at: Date()))
                    case .status(let id, let status):
                        continuation.yield(.status(id, status, receivedAt: Date()))
                    default:
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func startSurvey(_ plan: SurveyPlan) async throws {
        var capture = SurveyCapture()
        capture.wifiAP = plan.wifiAP
        capture.wifiClient = plan.wifiClient
        capture.wifiProbes = plan.wifiClient
        capture.ble = plan.ble
        capture.rawFrames = plan.rawFrames
        try await manager.startSurvey(capture)
    }

    public func stopSurvey() async {
        await manager.stopSurvey()
    }
}
