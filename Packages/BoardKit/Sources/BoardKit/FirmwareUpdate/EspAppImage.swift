import BoardProtocol
import Foundation

/// The facts the app reads from an ESP-IDF app image before sending it: the
/// image header's chip ID and the app description's version (esp_app_format.h,
/// esp_app_desc.h). Used to refuse an image for another chip early, and to show
/// the version of a do-it-yourself file.
public struct EspAppImage: Sendable, Equatable {
    public static let headerMagic: UInt8 = 0xE9
    static let descriptionMagic: UInt32 = 0xABCD_5432

    public let chipID: UInt16
    public let version: String?
    public let projectName: String?

    /// Nil when `data` does not start with an app image header.
    public init?(_ data: Data) {
        let bytes = [UInt8](data.prefix(112))
        guard bytes.count >= 24, bytes[0] == Self.headerMagic else { return nil }
        chipID = UInt16(bytes[12]) | UInt16(bytes[13]) << 8
        // esp_app_desc_t follows the 24-byte image header and the first 8-byte segment header.
        guard bytes.count >= 112, Self.uint32(bytes, at: 32) == Self.descriptionMagic else {
            version = nil
            projectName = nil
            return
        }
        version = Self.cString(bytes[48..<80])
        projectName = Self.cString(bytes[80..<112])
    }

    /// The board chip this image runs on, nil for chips no board uses.
    public var chip: NSBChip? {
        switch chipID {
        case 0x0017: .esp32C5
        case 0x000D: .esp32C6
        case 0x0009: .esp32S3
        case 0x0005: .esp32C3
        default: nil
        }
    }

    /// Readable chip name for messages.
    public var chipName: String {
        chip.map(\.displayName) ?? String(format: "chip ID 0x%04X", chipID)
    }

    private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }

    private static func cString(_ bytes: ArraySlice<UInt8>) -> String? {
        let text = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        return text.isEmpty ? nil : text
    }
}

extension NSBChip {
    public var displayName: String {
        switch self {
        case .esp32C5: "ESP32-C5"
        case .esp32C6: "ESP32-C6"
        case .esp32S3: "ESP32-S3"
        case .esp32C3: "ESP32-C3"
        case .other: "other chip"
        case .unspecified, .UNRECOGNIZED: "unknown chip"
        }
    }
}
