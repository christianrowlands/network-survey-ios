import BoardProtocol
import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import BoardKit

/// Serves fixed bytes per URL, like a release host.
final class FixtureFetcher: FirmwareFetching {
    let files: Mutex<[String: Data]>
    let requests = Mutex<[String]>([])

    init(_ files: [String: Data]) {
        self.files = Mutex(files)
    }

    func data(from url: URL, maxBytes: Int) async throws -> Data {
        requests.withLock { $0.append(url.absoluteString) }
        guard let data = files.withLock({ $0[url.absoluteString] }) else { throw URLError(.fileDoesNotExist) }
        guard data.count <= maxBytes else { throw FirmwareFetchError.tooLarge(limit: maxBytes) }
        return data
    }

    func set(_ url: String, _ data: Data) {
        files.withLock { $0[url] = data }
    }
}

/// A key generated per test run, standing in for a release key.
struct TestSigner {
    let key = Curve25519.Signing.PrivateKey()

    var publicKey: FirmwareSigningKey {
        FirmwareSigningKey(name: "test", base64: key.publicKey.rawRepresentation.base64EncodedString())!
    }

    var trust: FirmwareTrust { FirmwareTrust(keys: [publicKey]) }

    func sign(_ data: Data) -> Data {
        try! key.signature(for: data)
    }

    func signatureFile(_ data: Data) -> Data {
        Data((sign(data).base64EncodedString() + "\n").utf8)
    }

    /// A manifest in the sign-release.sh format for `images` (model, chip, image).
    func manifest(version: String, images: [(String, String, Data)], format: Int = 1, minVersion: String? = nil) -> Data {
        let entries = images.map { model, chip, image in
            """
                {"board": "test", "board_model": "\(model)", "chip": "\(chip)", "file": "\(model).bin",
                 "url": "\(model).bin", "size": \(image.count),
                 "sha256": "\(SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined())",
                 "signature": "\(sign(image).base64EncodedString())", "future_field": true}
            """
        }
        return Data("""
            {"format": \(format), "version": "\(version)", "protocol_major": 1, "protocol_minor": 0,\(minVersion.map { " \"min_version\": \"\($0)\"," } ?? "")
             "images": [\(entries.joined(separator: ","))]}
            """.utf8)
    }
}

func boardInfo(
    model: NSBBoardModel = .esp32C5Devkitc1, chip: NSBChip = .esp32C5, version: String = "0.1.0"
) -> NSBBoardInfo {
    .with {
        $0.boardModel = model
        $0.chip = chip
        $0.firmwareVersion = version
        $0.modelName = "Test board"
        $0.protocolMajor = 1
        $0.shortID = "AB12"
    }
}

@Suite("Firmware signature and manifest")
struct FirmwareVerificationTests {
    static let base = "https://releases.example.com/fw/"
    static let manifestURL = URL(string: base + "firmware-manifest.json")!

    // MARK: Signatures

    @Test func embeddedDevelopmentKeyVerifiesSignReleaseOutput() throws {
        let trust = FirmwareTrust.development
        let signature = try #require(FirmwareTrust.decodeSignature(FirmwareReleaseFixture.manifestSignature))
        let signer = try #require(trust.signer(of: FirmwareReleaseFixture.manifest, signature: signature))
        #expect(signer.isDevelopment)
        let manifest = try FirmwareManifest.decode(FirmwareReleaseFixture.manifest)
        #expect(manifest.version == "0.1.0")
        #expect(manifest.minVersion == "0.1.0")
        #expect(manifest.images.count == 2)
        for (image, chipID) in zip(manifest.images, [UInt16(0x17), 0x05]) {
            let data = FirmwareReleaseFixture.image(chipID: chipID)
            #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == image.sha256)
            let raw = try #require(FirmwareTrust.decodeSignature(Data(image.signature.utf8)))
            #expect(trust.signer(of: data, signature: raw) == FirmwareTrust.developmentKey)
        }
    }

    @Test func releaseTrustDoesNotIncludeTheDevelopmentKey() {
        #expect(!FirmwareTrust.release.keys.contains(FirmwareTrust.developmentKey))
        #expect(FirmwareTrust.release.keys.allSatisfy { !$0.isDevelopment })
        #expect(FirmwareTrust.development.keys.contains(FirmwareTrust.developmentKey))
    }

    @Test func tamperedImageFailsVerification() throws {
        let signer = TestSigner()
        var image = FirmwareReleaseFixture.image(chipID: 0x17)
        let signature = signer.sign(image)
        #expect(signer.trust.signer(of: image, signature: signature) != nil)
        image[700] ^= 0x01
        #expect(signer.trust.signer(of: image, signature: signature) == nil)
        #expect(throws: FirmwareUpdateError.signatureInvalid) {
            _ = try FirmwarePackage.file(image, signature: signer.signatureFile(FirmwareReleaseFixture.image(chipID: 0x17)), trust: signer.trust)
        }
    }

    @Test func wrongKeyFailsVerification() {
        let image = FirmwareReleaseFixture.image(chipID: 0x17)
        let other = TestSigner()
        #expect(TestSigner().trust.signer(of: image, signature: other.sign(image)) == nil)
        #expect(throws: FirmwareUpdateError.signatureInvalid) {
            _ = try FirmwarePackage.file(image, signature: other.signatureFile(image), trust: FirmwareTrust.development)
        }
        // The development key's fixture signature is not accepted by a release-only trust.
        #expect(throws: FirmwareUpdateError.signatureInvalid) {
            let signature = Data(FirmwareManifest.Image.fixtureC5.signature.utf8)
            _ = try FirmwarePackage.file(image, signature: signature, trust: FirmwareTrust(keys: []))
        }
    }

    @Test func signatureFormats() {
        let signer = TestSigner()
        let raw = signer.sign(Data("x".utf8))
        #expect(FirmwareTrust.decodeSignature(raw) == raw)
        #expect(FirmwareTrust.decodeSignature(Data((raw.base64EncodedString() + "\n").utf8)) == raw)
        #expect(FirmwareTrust.decodeSignature(Data("not base64".utf8)) == nil)
        #expect(FirmwareTrust.decodeSignature(Data(Data(count: 32).base64EncodedString().utf8)) == nil)
        #expect(FirmwareSigningKey(name: "bad", base64: "AAAA") == nil)
    }

    @Test func signedAndUnsignedFiles() throws {
        let signer = TestSigner()
        let image = FirmwareReleaseFixture.image(chipID: 0x17, version: "0.3.0-dev")
        let signed = try FirmwarePackage.file(image, signature: signer.signatureFile(image), trust: signer.trust)
        #expect(signed.origin == .signedFile(signer: "test", development: false))
        #expect(signed.isSigned)
        #expect(signed.version == "0.3.0-dev")

        let unsigned = try FirmwarePackage.file(image, signature: nil, trust: signer.trust)
        #expect(unsigned.origin == .unsignedFile)
        #expect(!unsigned.isSigned)
        #expect(unsigned.sha256 == Data(SHA256.hash(data: image)))
        #expect(throws: Never.self) { try unsigned.checkCompatible(with: boardInfo()) }
        #expect(throws: FirmwareUpdateError.wrongChip(board: "ESP32-C3", image: "ESP32-C5")) {
            try unsigned.checkCompatible(with: boardInfo(model: .esp32C3Generic, chip: .esp32C3))
        }
        #expect(throws: FirmwareUpdateError.notAnAppImage) {
            _ = try FirmwarePackage.file(Data(repeating: 0xFF, count: 4096), signature: nil, trust: signer.trust)
        }
    }

    @Test func appImageHeader() throws {
        let header = try #require(EspAppImage(FirmwareReleaseFixture.image(chipID: 0x0D, version: "1.2.3")))
        #expect(header.chip == .esp32C6)
        #expect(header.version == "1.2.3")
        #expect(header.projectName == "network_survey_board")
        var noDescription = FirmwareReleaseFixture.image(chipID: 0x09)
        noDescription[32] = 0
        let bare = try #require(EspAppImage(noDescription))
        #expect(bare.chip == .esp32S3)
        #expect(bare.version == nil)
        #expect(EspAppImage(FirmwareReleaseFixture.image(chipID: 0x02))?.chip == nil)
        #expect(EspAppImage(FirmwareReleaseFixture.image(chipID: 0x02))?.chipName == "chip ID 0x0002")
        #expect(EspAppImage(Data([0xE9, 1, 2])) == nil)
    }

    // MARK: Manifest

    @Test func manifestSelectsByModelAndChip() throws {
        let manifest = try FirmwareManifest.decode(FirmwareReleaseFixture.manifest)
        #expect(manifest.image(for: .esp32C5Devkitc1, chip: .esp32C5)?.board == "esp32c5-devkitc1")
        #expect(manifest.image(for: .esp32C3Generic, chip: .esp32C3)?.board == "esp32c3-devkitm1")
        #expect(manifest.image(for: .xiaoEsp32C5, chip: .esp32C5) == nil)  // Not in this release.
        #expect(manifest.image(for: .esp32C5Devkitc1, chip: .esp32C6) == nil)  // Model and chip must agree.
        #expect(manifest.image(for: .other, chip: .esp32C5) == nil)
        #expect(manifest.image(for: .UNRECOGNIZED(42), chip: .esp32C5) == nil)
        let url = FirmwareManifest.url(of: manifest.images[0], relativeTo: Self.manifestURL)
        #expect(url?.absoluteString == Self.base + "network-survey-board-esp32c5-devkitc1-0.1.0.bin")
        var absolute = manifest.images[0]
        absolute.url = "https://cdn.example.com/a.bin"
        #expect(FirmwareManifest.url(of: absolute, relativeTo: Self.manifestURL)?.absoluteString == "https://cdn.example.com/a.bin")
    }

    @Test func everyOfficialModelHasAManifestName() {
        let official: [(NSBBoardModel, NSBChip)] = [
            (.esp32C5Devkitc1, .esp32C5), (.xiaoEsp32C5, .esp32C5), (.esp32C6Generic, .esp32C6),
            (.esp32S3Generic, .esp32S3), (.esp32C3Generic, .esp32C3),
        ]
        for (model, chip) in official {
            #expect(model.manifestName != nil)
            #expect(chip.manifestName != nil)
        }
        #expect(Set(official.compactMap(\.0.manifestName)).count == official.count)
    }

    @Test func manifestRejectsBadInput() {
        let signer = TestSigner()
        let image = FirmwareReleaseFixture.image(chipID: 0x17)
        #expect(throws: FirmwareUpdateError.unsupportedManifestFormat(2)) {
            try FirmwareManifest.decode(signer.manifest(version: "1.0.0", images: [("ESP32_C5_DEVKITC_1", "ESP32_C5", image)], format: 2))
        }
        #expect(throws: FirmwareUpdateError.manifestInvalid("no format field")) {
            try FirmwareManifest.decode(Data("[]".utf8))
        }
        let badHash = String(decoding: FirmwareReleaseFixture.manifest, as: UTF8.self)
            .replacingOccurrences(of: "74cc0b741c", with: "zz")
        #expect(throws: FirmwareUpdateError.self) { try FirmwareManifest.decode(Data(badHash.utf8)) }
        // Unknown fields are ignored.
        #expect(throws: Never.self) {
            try FirmwareManifest.decode(signer.manifest(version: "1.0.0", images: [("ESP32_C5_DEVKITC_1", "ESP32_C5", image)]))
        }
    }

    // MARK: Versions

    @Test(arguments: [
        ("0.1.0", "0.2.0"), ("0.9.0", "0.10.0"), ("1.0.0-alpha", "1.0.0"), ("1.0.0-alpha", "1.0.0-alpha.1"),
        ("1.0.0-alpha.1", "1.0.0-alpha.beta"), ("1.0.0-beta.2", "1.0.0-beta.11"), ("1.0.0-rc.1", "1.0.0"),
        ("1.9.9", "2.0.0"), ("v0.1.0", "0.1.1"),
    ])
    func versionOrder(lower: String, higher: String) throws {
        let a = try #require(FirmwareVersion(lower))
        let b = try #require(FirmwareVersion(higher))
        #expect(a < b)
        #expect(!(b < a))
        #expect(FirmwareComparison(offered: higher, installed: lower) == .newer)
        #expect(FirmwareComparison(offered: lower, installed: higher) == .older)
    }

    @Test func versionParsing() {
        #expect(FirmwareVersion("1.2.3+build.5") == FirmwareVersion("1.2.3"))
        #expect(FirmwareVersion("1.2.3")?.description == "1.2.3")
        #expect(FirmwareVersion("1.2.3-rc.1")?.description == "1.2.3-rc.1")
        for bad in ["", "1.2", "1.2.3.4", "a.b.c", "1.2.3-", "1..3", "-1.0.0"] {
            #expect(FirmwareVersion(bad) == nil, "\(bad)")
        }
        #expect(FirmwareComparison(offered: "0.1.0", installed: "0.1.0") == .same)
        #expect(FirmwareComparison(offered: "0.1.0", installed: "custom") == .unknown)
        #expect(FirmwareComparison(offered: "custom", installed: "custom") == .same)
    }

    // MARK: Catalog

    func catalog(_ signer: TestSigner, version: String = "0.2.0", image: Data) -> (FirmwareCatalog, FixtureFetcher) {
        let manifest = signer.manifest(version: version, images: [("ESP32_C5_DEVKITC_1", "ESP32_C5", image)])
        let fetcher = FixtureFetcher([
            Self.manifestURL.absoluteString: manifest,
            Self.manifestURL.absoluteString + ".sig": signer.signatureFile(manifest),
            Self.base + "ESP32_C5_DEVKITC_1.bin": image,
        ])
        return (FirmwareCatalog(manifestURL: Self.manifestURL, trust: signer.trust, fetcher: fetcher), fetcher)
    }

    @Test func catalogOffersAndDownloadsAVerifiedImage() async throws {
        let signer = TestSigner()
        let image = FirmwareReleaseFixture.image(chipID: 0x17, version: "0.2.0", size: 5000)
        let (catalog, _) = catalog(signer, image: image)
        let offer = try await catalog.check(boardInfo(version: "0.1.0"))
        #expect(offer.comparison == .newer)
        #expect(offer.version == "0.2.0")
        #expect(offer.installedVersion == "0.1.0")
        let package = try await catalog.download(offer, for: boardInfo())
        #expect(package.image == image)
        #expect(package.version == "0.2.0")
        #expect(package.origin == .release(signer: "test", development: false))

        let same = try await catalog.check(boardInfo(version: "0.2.0"))
        #expect(same.comparison == .same)
        let older = try await catalog.check(boardInfo(version: "0.3.0"))
        #expect(older.comparison == .older)
        await #expect(throws: FirmwareUpdateError.noImageForBoard("Test board")) {
            try await catalog.check(boardInfo(model: .esp32C6Generic, chip: .esp32C6))
        }
    }

    @Test func catalogRefusesATamperedManifestOrImage() async throws {
        let signer = TestSigner()
        let image = FirmwareReleaseFixture.image(chipID: 0x17, version: "0.2.0", size: 5000)
        let (catalog, fetcher) = catalog(signer, image: image)
        let offer = try await catalog.check(boardInfo())

        // An image swapped on the server: size or hash no longer match the signed manifest.
        var swapped = image
        swapped[3000] ^= 0xFF
        fetcher.set(offer.imageURL.absoluteString, swapped)
        await #expect(throws: FirmwareUpdateError.imageCorrupt("SHA-256 differs")) {
            try await catalog.download(offer, for: boardInfo())
        }
        fetcher.set(offer.imageURL.absoluteString, image + Data([0]))
        await #expect(throws: FirmwareUpdateError.imageCorrupt("larger than the release says")) {
            try await catalog.download(offer, for: boardInfo())
        }

        // A manifest edited after signing.
        let manifest = signer.manifest(version: "9.9.9", images: [("ESP32_C5_DEVKITC_1", "ESP32_C5", image)])
        fetcher.set(Self.manifestURL.absoluteString, manifest)
        await #expect(throws: FirmwareUpdateError.manifestSignatureInvalid) { try await catalog.check(boardInfo()) }

        // Signed by another key.
        let stranger = TestSigner()
        fetcher.set(Self.manifestURL.absoluteString + ".sig", stranger.signatureFile(manifest))
        await #expect(throws: FirmwareUpdateError.manifestSignatureInvalid) { try await catalog.check(boardInfo()) }

        // Missing signature file.
        fetcher.files.withLock { $0[Self.manifestURL.absoluteString + ".sig"] = nil }
        await #expect(throws: FirmwareUpdateError.self) { try await catalog.check(boardInfo()) }
    }

    @Test func imageSignedByAnotherKeyIsRefusedEvenWithAValidManifest() async throws {
        let signer = TestSigner()
        let image = FirmwareReleaseFixture.image(chipID: 0x17, version: "0.2.0")
        let (catalog, _) = catalog(signer, image: image)
        var offer = try await catalog.check(boardInfo())
        var entry = offer.image
        entry.signature = TestSigner().sign(image).base64EncodedString()
        offer = FirmwareOffer(
            manifest: offer.manifest, image: entry, imageURL: offer.imageURL, signer: offer.signer,
            installedVersion: offer.installedVersion, comparison: offer.comparison
        )
        await #expect(throws: FirmwareUpdateError.signatureInvalid) { try await catalog.download(offer, for: boardInfo()) }
    }

    @Test func catalogRefusesAnImageForAnotherChip() async throws {
        let signer = TestSigner()
        // Listed for the C5 board but built for the C6.
        let image = FirmwareReleaseFixture.image(chipID: 0x0D, version: "0.2.0")
        let (catalog, _) = catalog(signer, image: image)
        let offer = try await catalog.check(boardInfo())
        await #expect(throws: FirmwareUpdateError.wrongChip(board: "ESP32-C5", image: "ESP32-C6")) {
            try await catalog.download(offer, for: boardInfo())
        }
    }

    @Test func noTrustedKeysAndNetworkErrors() async {
        let empty = FirmwareCatalog(manifestURL: Self.manifestURL, trust: FirmwareTrust(keys: []), fetcher: FixtureFetcher([:]))
        await #expect(throws: FirmwareUpdateError.noTrustedKeys) { try await empty.check(boardInfo()) }
        let offline = FirmwareCatalog(manifestURL: Self.manifestURL, trust: TestSigner().trust, fetcher: FixtureFetcher([:]))
        await #expect {
            try await offline.check(boardInfo())
        } throws: { error in
            if case .manifestUnavailable = error as? FirmwareUpdateError { return true }
            return false
        }
    }

    @Test func userMessagesHaveNoEmDashes() {
        let samples: [FirmwareUpdateError] = [
            .manifestUnavailable("x"), .manifestInvalid("x"), .manifestSignatureInvalid, .unsupportedManifestFormat(2),
            .noTrustedKeys, .noImageForBoard("x"), .downloadFailed("x"), .imageCorrupt("x"), .signatureInvalid,
            .notAnAppImage, .wrongChip(board: "a", image: "b"), .surveyRunning, .boardBusy, .notConnected,
            .connectionLost, .bondMissing, .pairingRejected, .boardRejected("x"), .imageTooLarge, .flashWriteFailed,
            .verifyFailed, .protocolError("x"), .boardDidNotReturn, .rolledBack(version: "1"),
            .unexpectedVersion(expected: "1", found: "2"), .cancelled, .staleRelease(version: "1", minimum: "2"),
            .fileChoice, .notConfirmed(version: "1"),
        ]
        for error in samples {
            #expect(!error.userMessage.isEmpty)
            #expect(!error.userMessage.contains("\u{2014}"))
        }
    }
}

extension FirmwareManifest.Image {
    static var fixtureC5: FirmwareManifest.Image {
        try! FirmwareManifest.decode(FirmwareReleaseFixture.manifest).images[0]
    }
}
