import BoardProtocol
import CryptoKit
import Foundation

/// A verified firmware image, ready to send to a board.
public struct FirmwarePackage: Sendable, Equatable {
    public enum Origin: Sendable, Equatable {
        /// From a signed release manifest.
        case release(signer: String, development: Bool)
        /// A local file with a valid signature from a trusted key.
        case signedFile(signer: String, development: Bool)
        /// A local file without a trusted signature (do-it-yourself build).
        case unsignedFile
    }

    public let image: Data
    public let sha256: Data
    /// The firmware version, from the manifest or the image header.
    public let version: String?
    public let origin: Origin
    public let header: EspAppImage
    /// A release newer than this one was verified before (the release host may
    /// be serving an old manifest).
    public let newerReleaseSeen: String?

    public var isSigned: Bool { origin != .unsignedFile }

    public var isRelease: Bool {
        if case .release = origin { true } else { false }
    }

    /// Checks a local file. A signature that is supplied must be valid; without
    /// one the package is unsigned and needs the user's explicit consent.
    public static func file(
        _ data: Data, signature: Data?, trust: FirmwareTrust
    ) throws(FirmwareUpdateError) -> FirmwarePackage {
        guard data.count <= FirmwareLimits.maxImageBytes else { throw .imageTooLarge }
        guard let header = EspAppImage(data) else { throw .notAnAppImage }
        var origin = Origin.unsignedFile
        if let signature {
            guard let raw = FirmwareTrust.decodeSignature(signature), let signer = trust.signer(of: data, signature: raw)
            else { throw .signatureInvalid }
            origin = .signedFile(signer: signer.name, development: signer.isDevelopment)
        }
        return FirmwarePackage(
            image: data, sha256: Data(SHA256.hash(data: data)), version: header.version, origin: origin, header: header
        )
    }

    init(
        image: Data, sha256: Data, version: String?, origin: Origin, header: EspAppImage, newerReleaseSeen: String? = nil
    ) {
        self.image = image
        self.sha256 = sha256
        self.version = version
        self.origin = origin
        self.header = header
        self.newerReleaseSeen = newerReleaseSeen
    }

    /// Refuses an image built for another chip than the board's.
    public func checkCompatible(with info: NSBBoardInfo) throws(FirmwareUpdateError) {
        guard header.chip == info.chip else {
            throw .wrongChip(board: info.chip.displayName, image: header.chipName)
        }
    }

    /// What the user must explicitly accept before this package goes to this
    /// board (protocol.md section 10: unsigned images, older versions, and
    /// files whose board model the app cannot check).
    public func requiredConsents(for info: NSBBoardInfo) -> [FirmwareConsent] {
        var consents: [FirmwareConsent] = []
        if origin == .unsignedFile { consents.append(.unsigned) }
        if !isRelease {
            // An app image does not name its board model; only the release manifest does.
            consents.append(.boardModel(info.modelName.isEmpty ? "this board" : info.modelName))
        }
        if let version {
            let comparison = FirmwareComparison(offered: version, installed: info.firmwareVersion)
            if comparison == .same || comparison == .older { consents.append(.notNewer(comparison)) }
        }
        if let newer = newerReleaseSeen { consents.append(.staleRelease(newer: newer)) }
        return consents
    }
}

/// Something the user must accept explicitly before an install.
public enum FirmwareConsent: Hashable, Sendable {
    /// Not signed by a trusted key.
    case unsigned
    /// A local file: the app cannot check that it was built for this board model.
    case boardModel(String)
    /// The same version or older than the board runs.
    case notNewer(FirmwareComparison)
    /// A newer release was verified before; this manifest may be stale.
    case staleRelease(newer: String)
}
