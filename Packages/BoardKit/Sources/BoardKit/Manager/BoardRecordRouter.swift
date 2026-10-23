import BoardProtocol
import Foundation
import Synchronization

/// Fans records out to consumers off the main actor and keeps per-board
/// counters, drop accounting and channel activity under a lock. Records never
/// wait for the UI; the manager copies counters into its observable state when
/// status arrives (about once a second per board).
final class BoardRecordRouter: Sendable {
    private struct DropBaseline {
        var uptimeMs: UInt64
        var records: UInt32
        var rawFrames: UInt32
        var rxFrames: UInt32
    }

    private struct State {
        var counters: [BoardID: BoardCounters] = [:]
        var baselines: [BoardID: DropBaseline] = [:]
        /// BSSIDs (packed into 48 bits) seen per channel this survey, capped.
        var bssidsByChannel: [UInt32: Set<UInt64>] = [:]
    }

    /// Past this many APs a channel counts as simply busy; keeps memory flat on long drives.
    static let maxBSSIDsPerChannel = 256

    let records = Broadcaster<BoardRecordEnvelope>()
    let batches = Broadcaster<(BoardID, ReceivedRecordBatch)>()
    let rawFrames = Broadcaster<BoardRawFrameEnvelope>()
    private let state = Mutex(State())

    func route(_ id: BoardID, _ received: ReceivedRecordBatch) {
        state.withLock { state in
            var counters = state.counters[id] ?? BoardCounters()
            counters.records += received.batch.records.count
            counters.batches += 1
            counters.missedNotifications += received.missedNotifications
            for record in received.batch.records {
                if let kind = record.recordKind { counters.recordsByKind[kind, default: 0] += 1 }
                if case .ap(let ap) = record.kind, state.bssidsByChannel[ap.channel, default: []].count < Self.maxBSSIDsPerChannel {
                    state.bssidsByChannel[ap.channel, default: []].insert(Self.pack(ap.bssid))
                }
            }
            state.counters[id] = counters
        }
        batches.send((id, received))
        let synced = received.batch.timeSynced
        for record in received.batch.records {
            records.send(BoardRecordEnvelope(
                boardID: id, receivedAt: received.receivedAt, boardTimeMs: synced ? record.boardTimeMs : nil, record: record
            ))
        }
    }

    func route(_ id: BoardID, _ received: ReceivedRawFrames) {
        state.withLock { state in
            state.counters[id, default: BoardCounters()].rawFrames += received.frames.count
            state.counters[id, default: BoardCounters()].missedRawNotifications += received.missedNotifications
        }
        for frame in received.frames {
            rawFrames.send(BoardRawFrameEnvelope(
                boardID: id, receivedAt: received.receivedAt, boardTimeUs: frame.timeSynced ? frame.boardTimeUs : nil, frame: frame
            ))
        }
    }

    /// Works out new board-side drops from the status counters, which only grow
    /// until the board reboots. The first status sets the baseline, so drops from
    /// before this phone saw the board are not counted; drops during a link gap are.
    func apply(_ status: NSBBoardStatus, from id: BoardID) -> (BoardCounters, BoardDrops) {
        state.withLock { state in
            let current = DropBaseline(
                uptimeMs: status.uptimeMs, records: status.droppedRecords, rawFrames: status.droppedRawFrames,
                rxFrames: status.droppedRxFrames
            )
            var drops = BoardDrops()
            if let last = state.baselines[id] {
                let rebooted = current.uptimeMs < last.uptimeMs
                drops.records = Self.delta(last.records, current.records, rebooted: rebooted)
                drops.rawFrames = Self.delta(last.rawFrames, current.rawFrames, rebooted: rebooted)
                drops.rxFrames = Self.delta(last.rxFrames, current.rxFrames, rebooted: rebooted)
            }
            state.baselines[id] = current
            var counters = state.counters[id] ?? BoardCounters()
            counters.droppedRecords += drops.records
            counters.droppedRawFrames += drops.rawFrames
            counters.droppedRxFrames += drops.rxFrames
            state.counters[id] = counters
            return (counters, drops)
        }
    }

    static func delta(_ old: UInt32, _ new: UInt32, rebooted: Bool) -> Int {
        rebooted || new < old ? Int(new) : Int(new - old)
    }

    func noteLinkGap(_ id: BoardID) {
        state.withLock { $0.counters[id, default: BoardCounters()].linkGaps += 1 }
    }

    func counters(_ id: BoardID) -> BoardCounters {
        state.withLock { $0.counters[id] ?? BoardCounters() }
    }

    static func pack(_ bssid: Data) -> UInt64 {
        bssid.prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// Counters and channel activity start again for a new survey. Drop
    /// baselines stay, since board-side drop counters only reset on reboot.
    func beginSurvey() {
        state.withLock { state in
            state.counters = [:]
            state.bssidsByChannel = [:]
        }
    }

    /// Channel weights for the planner: 1 plus the distinct BSSIDs seen there this survey.
    func channelWeights() -> [UInt32: Double] {
        state.withLock { state in state.bssidsByChannel.mapValues { 1 + Double($0.count) } }
    }

    func reset(_ id: BoardID) {
        state.withLock { state in
            state.counters[id] = nil
            state.baselines[id] = nil
        }
    }
}
