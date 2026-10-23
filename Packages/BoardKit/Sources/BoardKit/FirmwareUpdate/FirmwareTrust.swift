import CryptoKit
import Foundation

/// An Ed25519 public key that may sign board firmware.
public struct FirmwareSigningKey: Sendable, Hashable {
    public let name: String
    /// A development key: signs local test builds, never releases.
    public let isDevelopment: Bool
    public let rawRepresentation: Data

    public init?(name: String, base64: String, isDevelopment: Bool = false) {
        guard let raw = Data(base64Encoded: base64), (try? Curve25519.Signing.PublicKey(rawRepresentation: raw)) != nil
        else { return nil }
        self.name = name
        self.isDevelopment = isDevelopment
        rawRepresentation = raw
    }

    public func isValidSignature(_ signature: Data, for data: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawRepresentation) else { return false }
        return key.isValidSignature(signature, for: data)
    }
}

/// The keys the app accepts for firmware releases and signed image files
/// (docs/release-manifest.md in the firmware repository).
public struct FirmwareTrust: Sendable {
    public var keys: [FirmwareSigningKey]

    public init(keys: [FirmwareSigningKey]) {
        self.keys = keys
    }

    /// Release signing keys. Placeholder: the production key pair is not
    /// generated yet. Add its public half here (base64 of the raw 32 bytes)
    /// when the release key and its CI secret exist.
    public static let releaseKeys: [FirmwareSigningKey] = []

    /// What Release builds trust.
    public static let release = FirmwareTrust(keys: releaseKeys)

    #if DEBUG
    /// DEV / TEST ONLY key. Its private half never leaves the developer's
    /// machine and signs local test builds; the firmware repository has the
    /// same public key in scripts/keys/dev-signing-key.pub. Compiled into
    /// Debug builds only, so a Release binary cannot accept it.
    public static let developmentKey = FirmwareSigningKey(
        name: "Development key (test only)", base64: "+peeRxpEAL7CjQ0mWuX9HLKnqgTrMg+Ktjkr9fH0kBc=", isDevelopment: true
    )!

    /// What Debug builds trust: the release keys plus the development key.
    public static let development = FirmwareTrust(keys: releaseKeys + [developmentKey])
    #endif

    /// The trusted key that made `signature` over `data`, nil when none did.
    public func signer(of data: Data, signature: Data) -> FirmwareSigningKey? {
        guard signature.count == 64 else { return nil }
        return keys.first { $0.isValidSignature(signature, for: data) }
    }

    /// Decodes a signature file or manifest field: base64 text (as written by
    /// sign-release.sh) or the raw 64 bytes.
    public static func decodeSignature(_ data: Data) -> Data? {
        if data.count == 64 { return data }  // Base64 of 64 bytes is 88 characters.
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: text), raw.count == 64 else { return nil }
        return raw
    }
}
