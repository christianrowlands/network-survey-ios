import BoardProtocol
import Foundation

/// One record from one board, as SurveyCore consumes it.
public struct BoardRecordEnvelope: Sendable {
    public var boardID: BoardID
    public var receivedAt: Date
    /// Board time in Unix epoch ms, nil when the board clock was not synced yet.
    public var boardTimeMs: UInt64?
    public var record: NSBRecord

    public init(boardID: BoardID, receivedAt: Date, boardTimeMs: UInt64?, record: NSBRecord) {
        self.boardID = boardID
        self.receivedAt = receivedAt
        self.boardTimeMs = boardTimeMs
        self.record = record
    }
}

public struct BoardRawFrameEnvelope: Sendable {
    public var boardID: BoardID
    public var receivedAt: Date
    /// Receive time in Unix epoch µs, nil when the board clock was not synced yet.
    public var boardTimeUs: UInt64?
    public var frame: NSBRawFrame

    public init(boardID: BoardID, receivedAt: Date, boardTimeUs: UInt64?, frame: NSBRawFrame) {
        self.boardID = boardID
        self.receivedAt = receivedAt
        self.boardTimeUs = boardTimeUs
        self.frame = frame
    }
}

public enum BoardRecordKind: String, Sendable, CaseIterable, Codable {
    case ap, client, probe, ble, gps
}

extension NSBRecord {
    public var recordKind: BoardRecordKind? {
        switch kind {
        case .ap: .ap
        case .client: .client
        case .probe: .probe
        case .ble: .ble
        case .gps: .gps
        case nil: nil
        }
    }

    /// `board_time_ms` of whichever record this is.
    public var boardTimeMs: UInt64? {
        switch kind {
        case .ap(let record): record.boardTimeMs
        case .client(let record): record.boardTimeMs
        case .probe(let record): record.boardTimeMs
        case .ble(let record): record.boardTimeMs
        case .gps(let record): record.boardTimeMs
        case nil: nil
        }
    }
}

/// Per-board receive accounting, from the start of the current survey (or from
/// the first record when no survey was started).
public struct BoardCounters: Equatable, Sendable {
    public var records = 0
    public var batches = 0
    public var recordsByKind: [BoardRecordKind: Int] = [:]
    /// Records notifications lost on the link (sequence gaps).
    public var missedNotifications = 0
    public var rawFrames = 0
    public var missedRawNotifications = 0
    /// Drops the board reported in `BoardStatus` since this phone first saw it
    /// (ring full or record too large; raw rate limit; receive queue full).
    public var droppedRecords = 0
    public var droppedRawFrames = 0
    public var droppedRxFrames = 0
    /// Link interruptions while the board was wanted.
    public var linkGaps = 0

    public init() {}
}

/// Board-side drops found in one status update.
public struct BoardDrops: Equatable, Sendable {
    public var records = 0
    public var rawFrames = 0
    public var rxFrames = 0

    public var isEmpty: Bool { records == 0 && rawFrames == 0 && rxFrames == 0 }
}

public enum BoardCompatibility: Equatable, Sendable {
    case unknown
    case compatible(firmwareVersion: String)
    /// Hello failed: surveying is blocked; the reason is ready to show.
    case incompatible(reason: String)
}

/// Why a board needs the user's attention.
public enum BoardIssue: Equatable, Sendable {
    /// The board lost our bond (CBError 14): forget it in Settings > Bluetooth, then pair again.
    case bondMissing
    /// Pairing was cancelled, or the board is bonded to another phone and not in pairing mode.
    case pairingRejected
    case incompatible(String)
    case configureFailed(String)
}

public struct ReconnectState: Equatable, Sendable {
    public var attempt: Int
    public var nextAttempt: Date?
}

/// Backoff between reconnect attempts: `initialDelay` growing by `multiplier`
/// up to `maxDelay`. Attempts continue while the board is wanted.
public struct ReconnectPolicy: Equatable, Sendable {
    public var initialDelay: Duration
    public var multiplier: Double
    public var maxDelay: Duration
    /// Limit for one connect attempt. nil keeps a pending connect until the
    /// board is in range again (CoreBluetooth connects never time out).
    public var attemptTimeout: Duration?

    public init(initialDelay: Duration = .seconds(1), multiplier: Double = 2, maxDelay: Duration = .seconds(30), attemptTimeout: Duration? = nil) {
        self.initialDelay = initialDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.attemptTimeout = attemptTimeout
    }

    public static let standard = ReconnectPolicy()

    /// The wait after failed attempt number `attempt` (1-based).
    public func delay(afterAttempt attempt: Int) -> Duration {
        let factor = pow(max(multiplier, 1), Double(max(attempt - 1, 0)))
        let seconds = min(initialDelay.seconds * factor, maxDelay.seconds)
        return .milliseconds(Int64((seconds * 1000).rounded()))
    }
}

/// What a survey captures. The manager turns it into one Configure per board.
public struct SurveyCapture: Equatable, Sendable {
    public var wifiAP = true
    public var wifiClient = true
    public var wifiProbes = true
    public var ble = true
    public var rawFrames = false
    /// Channels the survey may use; empty means every supported channel.
    public var channels: [UInt32] = []
    public var dwell24Ms: UInt32 = 0
    public var dwell5Ms: UInt32 = 0
    public var rawSnaplen: UInt32 = 0
    public var rawMaxFramesPerSec: UInt32 = 0
    public var rawTypeMask: UInt32 = 0
    /// With two or more AUTO boards, make one the BLE sniffer.
    public var autoBLESniffer = true

    public init() {}

    public var wifi: Bool { wifiAP || wifiClient || wifiProbes || rawFrames }

    public func configure(for assignment: BoardAssignment) -> NSBConfigure {
        var configure = NSBConfigure()
        configure.wifiAp = wifiAP
        configure.wifiClient = wifiClient
        configure.wifiProbes = wifiProbes
        configure.rawFrames = rawFrames
        configure.ble = assignment.ble
        configure.role = assignment.role
        configure.channels = Array(assignment.channels.prefix(BoardLimits.configureChannels))
        configure.dwell24Ms = dwell24Ms
        configure.dwell5Ms = dwell5Ms
        configure.rawSnaplen = rawSnaplen
        configure.rawMaxFramesPerSec = rawMaxFramesPerSec
        configure.rawTypeMask = rawTypeMask
        return configure
    }
}

public enum BoardManagerEvent: Sendable, Equatable {
    /// Hello and SetTime done: the board takes commands.
    case ready(BoardID)
    case disconnected(BoardID, BoardDisconnectReason?)
    case incompatible(BoardID, reason: String)
    case bondMissing(BoardID)
    case pairingRejected(BoardID)
    /// A wanted board dropped; SurveyCore marks a gap in the session.
    case linkGapStarted(BoardID, at: Date)
    /// The gap closed: `resumed` is false when the board was given up.
    case linkGapEnded(BoardID, duration: TimeInterval, resumed: Bool)
    case reconnectAttemptFailed(BoardID, attempt: Int, error: String)
    case status(BoardID, NSBBoardStatus)
    case drops(BoardID, BoardDrops)
    case assignmentsChanged([BoardID: BoardAssignment])
}

public enum BoardManagerError: Error, Equatable {
    case incompatible(String)
    case rejected(NSBResultCode, String)
    /// Four boards are already in use.
    case tooManyBoards
    /// A connect for this board is already running.
    case busy
    case notReady
    /// A firmware update needs the survey stopped first.
    case surveyRunning
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
