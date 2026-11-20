import Foundation

/// What sent a Find My advertisement, by the device type bits of its status
/// byte. The raw value is those bits.
public enum FindMyDevice: Int, Sendable, CaseIterable {
    /// An iPhone, iPad, Mac or Apple Watch.
    case appleDevice = 0
    /// A first-generation AirTag.
    case airTag = 1
    /// A third-party Find My tracker or accessory, a second-generation AirTag
    /// or some AirPods. They can only be told apart by connecting to the
    /// device, which a passive survey does not do.
    case accessory = 2
    case airPods = 3

    /// AirTags and Find My accessories are tagged as trackers.
    public var isTracker: Bool {
        self == .airTag || self == .accessory
    }

    /// The raw values of the tracker types, for SQL filters.
    public static let trackerValues = allCases.filter(\.isTracker).map(\.rawValue)
}

/// Reads Apple Find My advertisements, with the same rules as the Network
/// Survey Android app.
///
/// Every Find My device (iPhones, Macs, AirPods, AirTags and third-party Find
/// My accessories) sends Apple's company ID with a payload of type 0x12, so
/// the type alone does not make a tracker. The payload is the type, a length
/// and then a status byte whose bits 4 and 5 say what sent it (see
/// `FindMyDevice`). Type 0x07 (Proximity Pairing) comes from AirPods and other
/// accessories, so it is not used.
public enum FindMy {
    public static let appleCompanyID: UInt16 = 0x004C
    static let findMyType: UInt8 = 0x12
    static let statusIndex = 2
    static let deviceTypeMask: UInt8 = 0x30
    static let deviceTypeShift: UInt8 = 4

    /// What sent the Find My advertisement in manufacturer specific data
    /// (company ID first, little endian, then the payload), or nil when it is
    /// not one. CoreBluetooth reports manufacturer data in this form, and the
    /// AD structure of type 0xFF holds it too.
    public static func device(manufacturerData: some Collection<UInt8>) -> FindMyDevice? {
        let bytes = Array(manufacturerData)
        guard bytes.count >= 2,
              UInt16(bytes[0]) | UInt16(bytes[1]) << 8 == appleCompanyID else { return nil }
        let payload = bytes.dropFirst(2)
        guard payload.first == findMyType, payload.count > statusIndex else { return nil }
        let status = payload[payload.startIndex + statusIndex]
        return FindMyDevice(rawValue: Int((status & deviceTypeMask) >> deviceTypeShift))
    }

    /// What sent the Find My advertisement in raw advertising data (AD
    /// structures), read from its first manufacturer specific data structure.
    public static func device(advertisingData: Data) -> FindMyDevice? {
        AdvertisingData(advertisingData).manufacturerData.flatMap { device(manufacturerData: $0) }
    }
}
