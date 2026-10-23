import BoardProtocol
import Foundation

/// GATT layout of the NS Board Service (protocol.md section 2).
public enum BoardGATT {
    public static let serviceUUID = "72AA0001-0D8E-4D18-8877-63C24ABE28D2"
    /// Bluetooth SIG company ID reserved for testing, used until a registered ID exists.
    public static let testCompanyID: UInt16 = 0xFFFF
}

public enum BoardCharacteristic: String, CaseIterable, Hashable, Sendable {
    case info, control, status, records, raw, ota

    public var uuidString: String {
        let group = switch self {
        case .info: "0002"
        case .control: "0003"
        case .status: "0004"
        case .records: "0005"
        case .raw: "0006"
        case .ota: "0007"
        }
        return "72AA\(group)-0D8E-4D18-8877-63C24ABE28D2"
    }

    public init?(uuidString: String) {
        guard let match = Self.allCases.first(where: { $0.uuidString.caseInsensitiveCompare(uuidString) == .orderedSame })
        else { return nil }
        self = match
    }

    /// Everything but Info needs an encrypted link with a stored bond.
    public var isEncrypted: Bool { self != .info }
}

/// The manufacturer specific data of a board advertisement (protocol.md section 1).
public struct BoardAdvertisement: Equatable, Sendable {
    public var companyID: UInt16
    public var protocolMajor: UInt8
    public var pairable: Bool
    public var hasBond: Bool
    public var hasGPS: Bool
    public var supports5GHz: Bool
    public var model: NSBBoardModel

    public init(
        companyID: UInt16 = BoardGATT.testCompanyID, protocolMajor: UInt8, pairable: Bool, hasBond: Bool,
        hasGPS: Bool, supports5GHz: Bool, model: NSBBoardModel
    ) {
        self.companyID = companyID
        self.protocolMajor = protocolMajor
        self.pairable = pairable
        self.hasBond = hasBond
        self.hasGPS = hasGPS
        self.supports5GHz = supports5GHz
        self.model = model
    }

    /// Parses the 5-byte payload as CoreBluetooth reports it (company ID first).
    /// The company ID is not checked: boards are found by service UUID, so a later
    /// change of company ID keeps working. Extra trailing bytes are ignored.
    public static func parse(manufacturerData data: Data) -> BoardAdvertisement? {
        let bytes = [UInt8](data)
        guard bytes.count >= 5 else { return nil }
        let flags = bytes[3]
        return BoardAdvertisement(
            companyID: UInt16(bytes[0]) | UInt16(bytes[1]) << 8,
            protocolMajor: bytes[2],
            pairable: flags & 0x01 != 0,
            hasBond: flags & 0x02 != 0,
            hasGPS: flags & 0x04 != 0,
            supports5GHz: flags & 0x08 != 0,
            model: NSBBoardModel(rawValue: Int(bytes[4])) ?? .unspecified
        )
    }

    public var encoded: Data {
        var flags: UInt8 = 0
        if pairable { flags |= 0x01 }
        if hasBond { flags |= 0x02 }
        if hasGPS { flags |= 0x04 }
        if supports5GHz { flags |= 0x08 }
        return Data([UInt8(companyID & 0xFF), UInt8(companyID >> 8), protocolMajor, flags, UInt8(truncatingIfNeeded: model.rawValue)])
    }

    /// "ABCD" from an advertised name "NS-ABCD", nil for any other name.
    public static func shortID(fromName name: String?) -> String? {
        guard let name, name.hasPrefix("NS-") else { return nil }
        let id = name.dropFirst(3)
        guard !id.isEmpty, id.count <= 7, id.allSatisfy(\.isHexDigit) else { return nil }
        return id.uppercased()
    }
}
