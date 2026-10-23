import BoardProtocol
import Foundation

extension BluetoothRecord {
    /// One BLE observation (one advertiser address per scan window). Service
    /// UUIDs, the company ID and manufacturer data come from the raw AD
    /// structures, as the Android app reads them.
    public init(ble: NSBBleObservation, context: RecordContext) {
        var data = BluetoothRecordData()
        data.apply(context)
        data.sourceAddress = WifiFields.mac(ble.address, uppercase: true)
        data.signalStrength = Float(ble.rssiMax)
        if ble.hasTxPower { data.txPower = Float(ble.txPower) }
        data.technology = .le
        let ad = AdvertisingData(ble.advData)
        data.supportedTechnologies = ad.supportedTechnologies
        data.otaDeviceName = ble.localNameText
        if ble.channel != 0 { data.channel = Int32(clamping: ble.channel) }
        switch ble.addressType {
        case .public: data.addressType = .public
        case .random: data.addressType = .random
        case .anonymous: data.addressType = .anonymous
        case .unspecified, .UNRECOGNIZED: break
        }
        data.serviceUuids = ad.serviceUUIDs
        if let manufacturer = ad.manufacturerData {
            let companyID = UInt16(manufacturer[0]) | UInt16(manufacturer[1]) << 8
            data.companyId = String(companyID, radix: 16)
            // Android writes the payload only when there is more than the ID.
            if manufacturer.count > 2 { data.mfgData = manufacturer.map { String(format: "%02x", $0) }.joined() }
        } else if ble.hasCompanyID {
            data.companyId = String(ble.companyID, radix: 16)
        }
        self.init(data: data)
    }
}

/// The parts of BLE advertising data (AD structures) the records use.
public struct AdvertisingData: Sendable, Equatable {
    /// Service UUIDs (AD types 0x02 to 0x07) in advertising order, as full
    /// lowercase 128-bit UUID strings.
    public var serviceUUIDs: [String] = []
    /// The first Manufacturer Specific Data structure, company ID included.
    public var manufacturerData: [UInt8]?
    /// The Flags structure, if present.
    public var flags: UInt8?

    public init(_ bytes: Data) {
        let raw = [UInt8](bytes)
        var index = 0
        while index < raw.count {
            let length = Int(raw[index])
            guard length > 0, index + length < raw.count else { break }
            let type = raw[index + 1]
            let value = Array(raw[(index + 2)..<(index + 1 + length)])
            switch type {
            case 0x01: if let first = value.first { flags = first }
            case 0x02, 0x03: serviceUUIDs += Self.uuids(value, size: 2)
            case 0x04, 0x05: serviceUUIDs += Self.uuids(value, size: 4)
            case 0x06, 0x07: serviceUUIDs += Self.uuids(value, size: 16)
            case 0xFF: if manufacturerData == nil && value.count >= 2 { manufacturerData = value }
            default: break
            }
            index += 1 + length
        }
    }

    /// From the Flags structure: "BR/EDR not supported" means LE only,
    /// otherwise the device supports both.
    public var supportedTechnologies: BluetoothSupportedTechnologies {
        guard let flags else { return .unknown }
        return flags & 0x04 != 0 ? .le : .dual
    }

    private static func uuids(_ value: [UInt8], size: Int) -> [String] {
        stride(from: 0, to: value.count - size + 1, by: size).map { start in
            let bytes = value[start..<(start + size)].reversed().map { String(format: "%02x", $0) }.joined()
            switch size {
            case 2: return "0000\(bytes)-0000-1000-8000-00805f9b34fb"
            case 4: return "\(bytes)-0000-1000-8000-00805f9b34fb"
            default:
                let chars = Array(bytes)
                let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(chars[$0]) }
                return groups.joined(separator: "-")
            }
        }
    }
}
