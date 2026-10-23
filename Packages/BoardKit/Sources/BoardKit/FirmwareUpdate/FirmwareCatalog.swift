import BoardProtocol
import CryptoKit
import Foundation

/// A release manifest whose signature checked out.
public struct VerifiedRelease: Sendable, Equatable {
    public let manifest: FirmwareManifest
    public let signer: FirmwareSigningKey
    /// A higher release was verified on this phone before: this manifest may be stale.
    public let newerVersionSeen: String?
}

/// A release image for one board, with how it compares to the board's firmware.
public struct FirmwareOffer: Sendable, Equatable {
    public let manifest: FirmwareManifest
    public let image: FirmwareManifest.Image
    public let imageURL: URL
    public let signer: FirmwareSigningKey
    public let installedVersion: String
    public let comparison: FirmwareComparison
    public var newerVersionSeen: String?

    public var version: String { manifest.version }
}

/// Finds, downloads and verifies official firmware for a board.
///
/// Limitation: the manifest carries no expiry, so a host serving an old but
/// validly signed manifest can hold boards on an older release. The signed
/// `min_version` and the per-phone `history` narrow this (docs/release-manifest.md).
public struct FirmwareCatalog: Sendable {
    /// The signed manifest of the latest firmware release, a release asset in
    /// the firmware repository. The app may override it with the
    /// `NSFirmwareManifestURL` user default.
    public static let defaultManifestURL = URL(
        string: "https://github.com/christianrowlands/network-survey-esp32/releases/latest/download/firmware-manifest.json"
    )!

    public var manifestURL: URL
    public var trust: FirmwareTrust
    public var fetcher: any FirmwareFetching
    public var history: (any FirmwareReleaseHistory)?
    /// Plain http for the manifest and images, for a local test server only.
    public var allowsInsecureHTTP: Bool

    public init(
        manifestURL: URL = defaultManifestURL, trust: FirmwareTrust, fetcher: any FirmwareFetching = URLSessionFirmwareFetcher(),
        history: (any FirmwareReleaseHistory)? = nil, allowsInsecureHTTP: Bool = false
    ) {
        self.manifestURL = manifestURL
        self.trust = trust
        self.fetcher = fetcher
        self.history = history
        self.allowsInsecureHTTP = allowsInsecureHTTP
    }

    /// Fetches the manifest and its signature, checks them, and applies the
    /// release history (refuses a release below the highest `min_version` seen).
    public func latestManifest() async throws(FirmwareUpdateError) -> VerifiedRelease {
        guard !trust.keys.isEmpty else { throw .noTrustedKeys }
        guard isAllowed(manifestURL), let signatureURL = Self.signatureURL(for: manifestURL) else {
            throw .manifestUnavailable("the release address must use https")
        }
        let body: Data
        let signatureFile: Data
        do {
            body = try await fetcher.data(from: manifestURL, maxBytes: FirmwareLimits.maxManifestBytes)
            signatureFile = try await fetcher.data(from: signatureURL, maxBytes: FirmwareLimits.maxManifestBytes)
        } catch {
            throw .manifestUnavailable(error.localizedDescription)
        }
        guard let signature = FirmwareTrust.decodeSignature(signatureFile),
              let signer = trust.signer(of: body, signature: signature)
        else { throw .manifestSignatureInvalid }
        let manifest = try FirmwareManifest.decode(body)

        let record = history?.load() ?? FirmwareReleaseRecord()
        if let floor = FirmwareReleaseRecord.higher(record.minimumVersion, manifest.minVersion),
           let version = FirmwareVersion(manifest.version), let minimum = FirmwareVersion(floor), version < minimum {
            throw .staleRelease(version: manifest.version, minimum: floor)
        }
        var newer: String?
        if let highest = record.highestVersion, let seen = FirmwareVersion(highest),
           let version = FirmwareVersion(manifest.version), seen > version {
            newer = highest
        }
        history?.save(record.merging(version: manifest.version, minimum: manifest.minVersion))
        return VerifiedRelease(manifest: manifest, signer: signer, newerVersionSeen: newer)
    }

    /// The image for this board in a verified manifest.
    public func offer(in release: VerifiedRelease, for info: NSBBoardInfo) throws(FirmwareUpdateError) -> FirmwareOffer {
        let manifest = release.manifest
        guard let image = manifest.image(for: info.boardModel, chip: info.chip),
              let url = FirmwareManifest.url(of: image, relativeTo: manifestURL)
        else {
            throw .noImageForBoard(info.modelName.isEmpty ? "this board" : info.modelName)
        }
        guard isAllowed(url) else { throw .manifestInvalid("image URL is not https") }
        return FirmwareOffer(
            manifest: manifest, image: image, imageURL: url, signer: release.signer, installedVersion: info.firmwareVersion,
            comparison: FirmwareComparison(offered: manifest.version, installed: info.firmwareVersion),
            newerVersionSeen: release.newerVersionSeen
        )
    }

    public func check(_ info: NSBBoardInfo) async throws(FirmwareUpdateError) -> FirmwareOffer {
        try offer(in: await latestManifest(), for: info)
    }

    /// Downloads the offered image and checks size, SHA-256, signature, version and chip.
    public func download(_ offer: FirmwareOffer, for info: NSBBoardInfo) async throws(FirmwareUpdateError) -> FirmwarePackage {
        let data: Data
        do {
            data = try await fetcher.data(from: offer.imageURL, maxBytes: min(offer.image.size, FirmwareLimits.maxImageBytes))
        } catch FirmwareFetchError.tooLarge {
            throw .imageCorrupt("larger than the release says")
        } catch {
            throw .downloadFailed(error.localizedDescription)
        }
        return try Self.verify(data, offer: offer, trust: trust, for: info)
    }

    static func verify(
        _ data: Data, offer: FirmwareOffer, trust: FirmwareTrust, for info: NSBBoardInfo
    ) throws(FirmwareUpdateError) -> FirmwarePackage {
        guard data.count == offer.image.size else {
            throw .imageCorrupt("size \(data.count), expected \(offer.image.size)")
        }
        let digest = Data(SHA256.hash(data: data))
        guard digest.hexString == offer.image.sha256.lowercased() else { throw .imageCorrupt("SHA-256 differs") }
        guard let signature = FirmwareTrust.decodeSignature(Data(offer.image.signature.utf8)),
              let signer = trust.signer(of: data, signature: signature)
        else { throw .signatureInvalid }
        guard let header = EspAppImage(data) else { throw .notAnAppImage }
        // sign-release.sh checks this too; it binds the manifest version to the image.
        guard header.version == nil || header.version == offer.version else {
            throw .imageCorrupt("the image is version \(header.version ?? ""), the release says \(offer.version)")
        }
        let package = FirmwarePackage(
            image: data, sha256: digest, version: offer.version,
            origin: .release(signer: signer.name, development: signer.isDevelopment), header: header,
            newerReleaseSeen: offer.newerVersionSeen
        )
        try package.checkCompatible(with: info)
        return package
    }

    private func isAllowed(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "https" || (allowsInsecureHTTP && scheme == "http")
    }

    /// The manifest URL with `.sig` added to its path (a query string stays in place).
    static func signatureURL(for manifest: URL) -> URL? {
        guard var components = URLComponents(url: manifest, resolvingAgainstBaseURL: true) else { return nil }
        components.path += ".sig"
        return components.url
    }
}
