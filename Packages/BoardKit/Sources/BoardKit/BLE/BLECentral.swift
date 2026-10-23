import Foundation

/// A thin, value-typed view of a BLE central (CoreBluetooth on device, a
/// simulated radio in tests). It mirrors CoreBluetooth closely: commands are
/// fire-and-forget and results arrive as events, in order, on one stream.
///
/// `BLEBoardTransport` holds all board logic on top of it, so that logic can be
/// tested without hardware.
public protocol BLECentral: AnyObject, Sendable {
    /// The single event stream. It is created with the central, so events from
    /// state restoration are kept until the transport starts reading.
    func events() -> AsyncStream<BLECentralEvent>

    var powerState: BLEPowerState { get }

    /// Scans for the NS Board Service UUID, reporting duplicates (for RSSI).
    func startScan()
    func stopScan()

    /// The subset of `ids` the system can still connect to (retrievePeripherals).
    func knownPeripherals(_ ids: [UUID]) -> [UUID]
    /// Starts a pending connect. It never times out by itself.
    func connect(_ id: UUID)
    func cancelConnection(_ id: UUID)

    /// Discovers the NS Board Service and its characteristics.
    func discoverGATT(_ id: UUID)
    func read(_ characteristic: BoardCharacteristic, on id: UUID)
    func setNotify(_ enabled: Bool, for characteristic: BoardCharacteristic, on id: UUID)
    func write(_ value: Data, to characteristic: BoardCharacteristic, on id: UUID, withResponse: Bool)

    func canSendWriteWithoutResponse(_ id: UUID) -> Bool
    /// The largest value for one write (ATT MTU - 3 for writes without response).
    func maximumWriteLength(_ id: UUID, withResponse: Bool) -> Int
}

public enum BLEPowerState: String, Sendable, Equatable {
    case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn
}

public struct BLEAdvertisementData: Sendable, Equatable {
    public var localName: String?
    public var serviceUUIDs: [String]
    public var manufacturerData: Data?
    public var isConnectable: Bool?

    public init(localName: String? = nil, serviceUUIDs: [String] = [], manufacturerData: Data? = nil, isConnectable: Bool? = nil) {
        self.localName = localName
        self.serviceUUIDs = serviceUUIDs
        self.manufacturerData = manufacturerData
        self.isConnectable = isConnectable
    }
}

public struct BLERestoredPeripheral: Sendable, Equatable {
    public enum State: Sendable, Equatable { case disconnected, connecting, connected }

    public var id: UUID
    public var state: State

    public init(id: UUID, state: State) {
        self.id = id
        self.state = state
    }
}

public enum BLECentralEvent: Sendable {
    case powerState(BLEPowerState)
    /// State restoration: the first event after an app relaunch by the system.
    case restored([BLERestoredPeripheral])
    case discovered(UUID, BLEAdvertisementData, rssi: Int, name: String?)
    case connected(UUID)
    case connectFailed(UUID, BLEError?)
    case disconnected(UUID, BLEError?)
    case gattDiscovered(UUID, BLEError?)
    /// A read result or a notification/indication.
    case valueUpdated(UUID, BoardCharacteristic, Data, BLEError?)
    case wroteValue(UUID, BoardCharacteristic, BLEError?)
    case notifyStateChanged(UUID, BoardCharacteristic, enabled: Bool, BLEError?)
    case readyToWriteWithoutResponse(UUID)
}

/// A CoreBluetooth error as a value. The domains and codes match `CBErrorDomain`
/// and `CBATTErrorDomain`, so the mapping is testable without the framework.
public struct BLEError: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// CBError 14: the peer removed its pairing information (stale bond on the phone).
        case peerRemovedPairingInformation
        /// CBError 15: encryption timed out (can also mean a stale bond).
        case encryptionTimedOut
        /// ATT 0x05, 0x0F and 0x08: the board refused access on this link.
        case insufficientAuthentication
        case insufficientEncryption
        case insufficientAuthorization
        case connectionTimeout
        case connectionFailed
        case notConnected
        case notFound
        case other
    }

    public static let cbErrorDomain = "CBErrorDomain"
    public static let attErrorDomain = "CBATTErrorDomain"

    public var kind: Kind
    public var domain: String
    public var code: Int
    public var message: String

    public init(kind: Kind, domain: String = "", code: Int = 0, message: String = "") {
        self.kind = kind
        self.domain = domain
        self.code = code
        self.message = message
    }

    public init(domain: String, code: Int, message: String = "") {
        self.init(kind: Self.kind(domain: domain, code: code), domain: domain, code: code, message: message)
    }

    public init(_ error: any Error) {
        let ns = error as NSError
        self.init(domain: ns.domain, code: ns.code, message: ns.localizedDescription)
    }

    static func kind(domain: String, code: Int) -> Kind {
        switch (domain, code) {
        case (cbErrorDomain, 14): .peerRemovedPairingInformation
        case (cbErrorDomain, 15): .encryptionTimedOut
        case (cbErrorDomain, 6): .connectionTimeout
        case (cbErrorDomain, 7): .notConnected
        case (cbErrorDomain, 10): .connectionFailed
        case (attErrorDomain, 0x05): .insufficientAuthentication
        case (attErrorDomain, 0x0F): .insufficientEncryption
        case (attErrorDomain, 0x08): .insufficientAuthorization
        default: .other
        }
    }

    public static let peerRemovedPairing = BLEError(domain: cbErrorDomain, code: 14, message: "Peer removed pairing information")
    public static let encryptionTimedOut = BLEError(domain: cbErrorDomain, code: 15, message: "Encryption timed out")
    public static let insufficientAuthentication = BLEError(domain: attErrorDomain, code: 0x05, message: "Authentication is insufficient")
    public static let insufficientAuthorization = BLEError(domain: attErrorDomain, code: 0x08, message: "Authorization is insufficient")

    /// What this error means for a board link.
    var transportError: BoardTransportError {
        switch kind {
        case .peerRemovedPairingInformation: .bondMissing
        case .insufficientAuthentication, .insufficientEncryption, .insufficientAuthorization, .encryptionTimedOut:
            .pairingRejected
        case .notConnected: .notConnected
        case .connectionTimeout: .timeout
        case .notFound: .unknownBoard
        case .connectionFailed, .other: .connectionFailed(message.isEmpty ? "\(domain) \(code)" : message)
        }
    }
}
