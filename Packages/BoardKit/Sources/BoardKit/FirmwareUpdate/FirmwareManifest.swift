import BoardProtocol
import Foundation

/// The signed release manifest (docs/release-manifest.md in the firmware
/// repository). Unknown fields are ignored.
public struct FirmwareManifest: Decodable, Sendable, Equatable {
    public static let supportedFormat = 1

    public var format: Int
    public var name: String?
    public var version: String
    /// Oldest version still considered safe. The app refuses releases below
    /// the highest `min_version` it has verified (a replayed old manifest).
    public var minVersion: String?
    public var protocolMajor: UInt32?
    public var protocolMinor: UInt32?
    public var released: String?
    public var images: [Image]

    public struct Image: Decodable, Sendable, Equatable {
        public var board: String?
        /// `BoardModel` enum name without the `BOARD_MODEL_` prefix.
        public var boardModel: String
        /// `Chip` enum name without the `CHIP_` prefix.
        public var chip: String
        public var file: String?
        /// Absolute, or relative to the manifest URL.
        public var url: String
        public var size: Int
        /// Lowercase hex.
        public var sha256: String
        /// Ed25519 over the image bytes, base64.
        public var signature: String
    }

    public static func decode(_ data: Data) throws(FirmwareUpdateError) -> FirmwareManifest {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        struct Header: Decodable { var format: Int }
        guard let header = try? decoder.decode(Header.self, from: data) else {
            throw .manifestInvalid("no format field")
        }
        guard header.format == supportedFormat else { throw .unsupportedManifestFormat(header.format) }
        let manifest: FirmwareManifest
        do {
            manifest = try decoder.decode(FirmwareManifest.self, from: data)
        } catch {
            throw .manifestInvalid(String(describing: error))
        }
        guard !manifest.version.isEmpty else { throw .manifestInvalid("empty version") }
        if let minimum = manifest.minVersion {
            guard let floor = FirmwareVersion(minimum), let version = FirmwareVersion(manifest.version), floor <= version
            else { throw .manifestInvalid("min_version \(minimum) above version \(manifest.version)") }
        }
        for image in manifest.images {
            guard image.size > 0, image.size <= FirmwareLimits.maxImageBytes, Data(hexString: image.sha256)?.count == 32,
                  FirmwareTrust.decodeSignature(Data(image.signature.utf8)) != nil
            else { throw .manifestInvalid("bad image entry for \(image.boardModel)") }
        }
        return manifest
    }

    /// The image for a board, matched on both model and chip.
    public func image(for model: NSBBoardModel, chip: NSBChip) -> Image? {
        guard let modelName = model.manifestName, let chipName = chip.manifestName else { return nil }
        return images.first { $0.boardModel == modelName && $0.chip == chipName }
    }

    public static func url(of image: Image, relativeTo manifestURL: URL) -> URL? {
        URL(string: image.url, relativeTo: manifestURL)?.absoluteURL
    }
}

extension NSBBoardModel {
    /// The name the release manifest uses; nil for boards without official images.
    public var manifestName: String? {
        switch self {
        case .esp32C5Devkitc1: "ESP32_C5_DEVKITC_1"
        case .xiaoEsp32C5: "XIAO_ESP32_C5"
        case .esp32C6Generic: "ESP32_C6_GENERIC"
        case .esp32S3Generic: "ESP32_S3_GENERIC"
        case .esp32C3Generic: "ESP32_C3_GENERIC"
        case .unspecified, .other, .UNRECOGNIZED: nil
        }
    }
}

extension NSBChip {
    public var manifestName: String? {
        switch self {
        case .esp32C5: "ESP32_C5"
        case .esp32C6: "ESP32_C6"
        case .esp32S3: "ESP32_S3"
        case .esp32C3: "ESP32_C3"
        case .unspecified, .other, .UNRECOGNIZED: nil
        }
    }
}

extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
