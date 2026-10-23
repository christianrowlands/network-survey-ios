import BoardProtocol
import Foundation

/// The hardware a simulated board pretends to be.
public struct SimulatedBoardProfile: Sendable, Identifiable {
    /// The stable board ID (from `btAddress` for the standard profiles).
    public var id: BoardID
    /// What CoreBluetooth would call the board on this phone (SimulatedBLECentral).
    public var peripheralID: UUID
    public var shortID: String
    public var btAddress: [UInt8]
    public var model: NSBBoardModel
    public var chip: NSBChip
    public var bands: [NSBBand]
    public var firmwareVersion: String
    /// Battery voltage, or nil when the board runs from USB.
    public var batteryMilliVolts: UInt32?
    public var mtu: UInt32
    /// Advertising RSSI as seen by the phone.
    public var advertisingRSSI: Int
    /// Protocol major the firmware speaks (set it to test incompatible boards).
    public var protocolMajor = UInt32(NSBProtocolVersion.major.rawValue)

    public init(
        id: BoardID, shortID: String, btAddress: [UInt8], model: NSBBoardModel, chip: NSBChip,
        bands: [NSBBand], firmwareVersion: String = "1.0.0", batteryMilliVolts: UInt32? = nil,
        mtu: UInt32 = 247, advertisingRSSI: Int = -55, peripheralID: UUID = UUID()
    ) {
        self.id = id
        self.peripheralID = peripheralID
        self.shortID = shortID
        self.btAddress = btAddress
        self.model = model
        self.chip = chip
        self.bands = bands
        self.firmwareVersion = firmwareVersion
        self.batteryMilliVolts = batteryMilliVolts
        self.mtu = mtu
        self.advertisingRSSI = advertisingRSSI
    }

    public var name: String { "NS-\(shortID)" }

    public var supportedChannels: [UInt32] { WifiChannels.supported(bands: bands) }

    public var boardInfo: NSBBoardInfo {
        var info = NSBBoardInfo()
        info.protocolMajor = protocolMajor
        info.protocolMinor = UInt32(NSBProtocolVersion.minor.rawValue)
        info.firmwareVersion = firmwareVersion
        info.boardModel = model
        info.chip = chip
        info.bands = bands
        info.gpsPresent = false
        info.shortID = shortID
        info.preferredMtu = mtu
        info.btAddress = Data(btAddress)
        info.modelName = "Demo board"
        return info
    }

    /// A standard set of boards for `count` simulated boards: a dual-band
    /// DevKitC, a battery-powered dual-band XIAO, a 2.4 GHz-only C6, and another
    /// DevKitC. Addresses, IDs and peripheral identifiers depend only on the seed
    /// and the index.
    public static func standard(count: Int, seed: UInt64) -> [SimulatedBoardProfile] {
        (0..<count).map { index in
            var rng = SeededGenerator(seed: seed).derived(100 + UInt64(index))
            var address = rng.bytes(6)
            address[0] |= 0xC0  // BLE random static address.
            let shortID = String(format: "%02X%02X", address[4], address[5])
            var uuidBytes = rng.bytes(16)
            uuidBytes[6] = (uuidBytes[6] & 0x0F) | 0x40
            uuidBytes[8] = (uuidBytes[8] & 0x3F) | 0x80
            let uuid = UUID(uuid: (
                uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3], uuidBytes[4], uuidBytes[5],
                uuidBytes[6], uuidBytes[7], uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
                uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
            ))
            let id = BoardID(btAddress: Data(address))!
            let dualBand: [NSBBand] = [.ghz24, .ghz5]
            switch index % 4 {
            case 1:
                return SimulatedBoardProfile(
                    id: id, shortID: shortID, btAddress: address, model: .xiaoEsp32C5, chip: .esp32C5,
                    bands: dualBand, batteryMilliVolts: 3_950, advertisingRSSI: -61, peripheralID: uuid
                )
            case 2:
                return SimulatedBoardProfile(
                    id: id, shortID: shortID, btAddress: address, model: .esp32C6Generic, chip: .esp32C6,
                    bands: [.ghz24], advertisingRSSI: -67, peripheralID: uuid
                )
            default:
                return SimulatedBoardProfile(
                    id: id, shortID: shortID, btAddress: address, model: .esp32C5Devkitc1, chip: .esp32C5,
                    bands: dualBand, advertisingRSSI: -52 - index, peripheralID: uuid
                )
            }
        }
    }
}
