import Foundation

/// One advertisement this iPhone heard, as CoreBluetooth reports it. There is
/// no device address: iOS hides it and instead gives each peripheral an
/// identifier that only means something on this iPhone.
public struct NearbyAdvertisement: Sendable, Equatable {
    /// CoreBluetooth's identifier for the peripheral. Never shown as an address.
    public var peripheralID: UUID
    public var time: Date
    public var rssi: Int
    public var localName: String?
    public var manufacturerData: Data?
    /// Advertised service UUIDs, upper case ("FE9F" or a full UUID).
    public var serviceUUIDs: [String]
    /// UUIDs that came with service data.
    public var serviceDataUUIDs: [String]
    public var txPower: Int?
    public var isConnectable: Bool?

    public init(
        peripheralID: UUID, time: Date, rssi: Int, localName: String? = nil, manufacturerData: Data? = nil,
        serviceUUIDs: [String] = [], serviceDataUUIDs: [String] = [], txPower: Int? = nil, isConnectable: Bool? = nil
    ) {
        self.peripheralID = peripheralID
        self.time = time
        self.rssi = rssi
        self.localName = localName
        self.manufacturerData = manufacturerData
        self.serviceUUIDs = serviceUUIDs
        self.serviceDataUUIDs = serviceDataUUIDs
        self.txPower = txPower
        self.isConnectable = isConnectable
    }

    /// The Bluetooth SIG company identifier: the first two bytes of the
    /// manufacturer data, little endian.
    public var companyID: Int? {
        Self.companyID(manufacturerData)
    }

    static func companyID(_ data: Data?) -> Int? {
        guard let data, data.count >= 2 else { return nil }
        let start = data.startIndex
        return Int(data[start]) | Int(data[data.index(after: start)]) << 8
    }
}

/// The radio as this app can use it for Nearby Bluetooth.
public enum NearbyRadioState: Sendable, Equatable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn
}

/// Whether the user allowed this app to use Bluetooth.
public enum NearbyAuthorization: Sendable, Equatable {
    /// Never asked. The first Look asks.
    case notDetermined
    case denied
    case restricted
    case allowed
}

public enum NearbyScannerEvent: Sendable, Equatable {
    case state(NearbyRadioState)
    case advertisement(NearbyAdvertisement)
}

/// Listens for Bluetooth LE advertisements. `events()` has one consumer.
public protocol NearbyScanner: AnyObject, Sendable {
    var authorization: NearbyAuthorization { get }
    /// The radio now. `.unknown` until the first `start()`.
    var radio: NearbyRadioState { get }
    func events() -> AsyncStream<NearbyScannerEvent>
    /// Starts listening. The first call may show the system Bluetooth prompt.
    func start()
    func stop()
}
