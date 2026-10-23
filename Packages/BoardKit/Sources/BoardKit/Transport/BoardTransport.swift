import BoardProtocol
import Foundation

/// A source of Network Survey boards: real hardware over BLE, or the simulator.
///
/// Discovery and board events are delivered as async streams. Each call to
/// `discoveries()` or `events()` returns a new stream, so several consumers can
/// listen at once. Streams end when the transport is shut down.
public protocol BoardTransport: AnyObject, Sendable {
    /// The boards currently seen while scanning. Every element is the full list.
    /// A new stream starts with the latest list.
    func discoveries() -> AsyncStream<[DiscoveredBoard]>

    /// Connection state changes, record batches, raw frames, status updates and
    /// OTA acks of every board this transport is connected to.
    func events() -> AsyncStream<BoardEvent>

    func startScanning() async
    func stopScanning() async

    /// Connects, reads `BoardInfo` and subscribes to the encrypted characteristics,
    /// which pairs on first use. Returns when the board is ready for Hello.
    /// With a nil timeout a BLE transport keeps a pending connect until the board
    /// is in range again.
    func connect(_ board: BoardID, timeout: Duration?) async throws(BoardTransportError)
    func disconnect(_ board: BoardID) async

    /// Reads `BoardInfo` without pairing (connecting briefly if needed).
    func readInfo(_ board: BoardID) async throws(BoardTransportError) -> NSBBoardInfo

    /// Sends one control request and waits for the response with the same
    /// request ID. Requests to one board are sent one at a time.
    func send(
        _ request: NSBControlRequest, to board: BoardID, timeout: Duration
    ) async throws(BoardTransportError) -> NSBControlResponse

    /// Largest OTA write (4-byte offset plus image bytes), nil when not connected.
    func maximumOTAWriteLength(for board: BoardID) async -> Int?

    /// Writes one OTA chunk without response, waiting for link flow control first.
    func writeOTAChunk(_ chunk: Data, to board: BoardID) async throws(BoardTransportError)

    /// The current state of every board the transport has seen connect. Lets a
    /// late subscriber catch up (for example boards restored at app launch).
    func connectionStates() async -> [BoardID: BoardConnectionState]

    /// Boards this phone has paired with and not removed, for silent reconnects.
    func knownBoards() async -> [KnownBoard]
    /// Stops treating the board as in use. `keepBond`: the board stays known as
    /// removed (both sides keep the bond, so adding it back needs no pairing);
    /// otherwise it is forgotten entirely.
    func forgetKnownBoard(_ board: BoardID, keepBond: Bool) async
}

/// Control response timeouts from the protocol: 5 s, and 30 s for OtaEnd.
public enum ControlTimeout {
    public static let standard: Duration = .seconds(5)
    public static let otaEnd: Duration = .seconds(30)

    public static func `for`(_ request: NSBControlRequest) -> Duration {
        if case .otaEnd? = request.command { return otaEnd }
        return standard
    }
}

extension BoardTransport {
    /// Connects with a 15 second limit, for user-initiated connects.
    public func connect(_ board: BoardID) async throws(BoardTransportError) {
        try await connect(board, timeout: .seconds(15))
    }

    public func send(_ request: NSBControlRequest, to board: BoardID) async throws(BoardTransportError) -> NSBControlResponse {
        try await send(request, to: board, timeout: ControlTimeout.for(request))
    }
}

/// Identifies a board. Once its `BoardInfo` is known this is `NS-` plus the
/// board's BLE identity address in uppercase hex (`NS-02005E00ABCD`): the same
/// on every phone and after reinstalls, so it can go into files and become the
/// NS Messaging sensor ID. A board this phone has never read Info from (seen
/// only in a scan) has a provisional ID, its CoreBluetooth peripheral UUID; it
/// becomes stable once the board is connected (`BoardManager.connect` returns
/// the stable ID) and stays stable for known boards.
public struct BoardID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// A provisional ID: a CoreBluetooth peripheral identifier.
    public init(_ uuid: UUID) {
        rawValue = uuid.uuidString
    }

    /// The stable ID for a 6-byte BLE identity address.
    public init?(btAddress: Data) {
        guard btAddress.count == 6 else { return nil }
        rawValue = "NS-" + btAddress.map { String(format: "%02X", $0) }.joined()
    }

    /// The stable ID from `BoardInfo.bt_address`, nil when the board sent none.
    public init?(info: NSBBoardInfo) {
        self.init(btAddress: info.btAddress)
    }

    public var description: String { rawValue }

    /// Derived from the board's address, so the same everywhere.
    public var isStable: Bool { rawValue.hasPrefix("NS-") }

    /// The peripheral identifier of a provisional ID.
    var peripheralUUID: UUID? { UUID(uuidString: rawValue) }

    public init(from decoder: any Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            rawValue = value
            return
        }
        // Stored before IDs were strings: {"uuid": "..."}.
        enum Legacy: String, CodingKey { case uuid }
        rawValue = try decoder.container(keyedBy: Legacy.self).decode(UUID.self, forKey: .uuid).uuidString
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A board seen in advertising.
public struct DiscoveredBoard: Identifiable, Hashable, Sendable {
    public let id: BoardID
    /// Advertised name, "NS-XXXX".
    public var name: String
    public var shortID: String
    public var rssi: Int
    public var model: NSBBoardModel
    public var protocolMajor: UInt32
    /// Pairable: no bonds yet, or an explicit pairing window is open.
    public var pairingMode: Bool
    public var hasBond: Bool
    public var hasGPS: Bool
    public var supports5GHz: Bool
    /// This phone has paired with the board before (including a removed board).
    public var isKnown: Bool
    /// Known, but the user removed it in the app. Both sides still hold the
    /// bond, so connecting again needs no pairing.
    public var isRemoved: Bool
    public var isSimulated: Bool
    public var lastSeen: Date

    public init(
        id: BoardID, name: String, shortID: String, rssi: Int, model: NSBBoardModel,
        protocolMajor: UInt32, pairingMode: Bool, hasBond: Bool, hasGPS: Bool = false,
        supports5GHz: Bool = false, isKnown: Bool = false, isRemoved: Bool = false, isSimulated: Bool, lastSeen: Date
    ) {
        self.id = id
        self.name = name
        self.shortID = shortID
        self.rssi = rssi
        self.model = model
        self.protocolMajor = protocolMajor
        self.pairingMode = pairingMode
        self.hasBond = hasBond
        self.hasGPS = hasGPS
        self.supports5GHz = supports5GHz
        self.isKnown = isKnown
        self.isRemoved = isRemoved
        self.isSimulated = isSimulated
        self.lastSeen = lastSeen
    }

    /// Bonded to another phone and not pairable: this phone cannot use it now.
    public var isUnavailable: Bool { hasBond && !pairingMode && !isKnown }

    /// Known to this phone but advertising no bond: it was reflashed or its
    /// pairings were erased, so the phone's half of the bond is stale.
    public var wasReset: Bool { isKnown && !hasBond && !isSimulated }
}

public enum BoardConnectionState: Equatable, Sendable {
    case disconnected(BoardDisconnectReason?)
    case connecting
    case connected(NSBBoardInfo)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var isDisconnected: Bool {
        if case .disconnected = self { return true }
        return false
    }
}

public enum BoardDisconnectReason: Equatable, Sendable {
    /// The app asked to disconnect.
    case requested
    /// The link dropped (out of range, board reset, power loss).
    case linkLost
    /// The board no longer has our bond (CBError 14); the user must forget the
    /// board in iOS Settings > Bluetooth and pair again.
    case bondMissing
    /// Pairing did not complete: cancelled on the phone, or the board is not
    /// pairable (bonded to another phone and no pairing window open).
    case pairingRejected
    case failed(String)
}

public enum BoardEvent: Sendable {
    case connectionState(BoardID, BoardConnectionState)
    case records(BoardID, ReceivedRecordBatch)
    case status(BoardID, NSBBoardStatus)
    case rawFrames(BoardID, ReceivedRawFrames)
    case otaAck(BoardID, NSBOtaAck)
    /// Bluetooth on the phone changed state (BLE transports only).
    case bluetooth(BLEPowerState)
}

/// One RecordBatch as it arrived, with what the framing layer saw.
public struct ReceivedRecordBatch: Sendable {
    /// Sequence number of the notification that carried the batch.
    public var sequence: UInt16
    /// Notifications lost on the Records characteristic just before this one.
    public var missedNotifications: Int
    public var batch: NSBRecordBatch
    public var receivedAt: Date

    public init(sequence: UInt16, missedNotifications: Int, batch: NSBRecordBatch, receivedAt: Date) {
        self.sequence = sequence
        self.missedNotifications = missedNotifications
        self.batch = batch
        self.receivedAt = receivedAt
    }
}

/// The raw frames of one Raw notification.
public struct ReceivedRawFrames: Sendable {
    public var sequence: UInt16
    /// Notifications lost on the Raw characteristic just before this one.
    public var missedNotifications: Int
    public var frames: [NSBRawFrame]
    public var receivedAt: Date

    public init(sequence: UInt16, missedNotifications: Int, frames: [NSBRawFrame], receivedAt: Date) {
        self.sequence = sequence
        self.missedNotifications = missedNotifications
        self.frames = frames
        self.receivedAt = receivedAt
    }
}

public enum BoardTransportError: Error, Equatable, Sendable {
    case unknownBoard
    case notConnected
    case connectionFailed(String)
    case timeout
    case malformedResponse
    case invalidRequest(String)
    case writeFailed(String)
    /// Bluetooth is off, unauthorized or unsupported.
    case bluetoothUnavailable(String)
    /// CBError 14: the board wiped its bond, iOS still holds its half.
    case bondMissing
    case pairingRejected
    case unsupported
    case cancelled
}
