import BoardProtocol
import CryptoKit
import Foundation
import Testing
@testable import BoardKit

/// Consents, release history (replay), transport limits and strict versions.
@Suite("Firmware update policy")
struct FirmwarePolicyTests {
    static let base = "https://releases.example.com/fw/"
    static let manifestURL = URL(string: base + "firmware-manifest.json")!

    func host(_ signer: TestSigner, version: String, minVersion: String? = nil, image: Data) -> FixtureFetcher {
        let manifest = signer.manifest(
            version: version, images: [("ESP32_C5_DEVKITC_1", "ESP32_C5", image)], minVersion: minVersion
        )
        return FixtureFetcher([
            Self.manifestURL.absoluteString: manifest,
            Self.manifestURL.absoluteString + ".sig": signer.signatureFile(manifest),
            Self.base + "ESP32_C5_DEVKITC_1.bin": image,
        ])
    }

    func publish(_ fetcher: FixtureFetcher, _ signer: TestSigner, version: String, minVersion: String? = nil, image: Data) {
        let manifest = signer.manifest(
            version: version, images: [("ESP32_C5_DEVKITC_1", "ESP32_C5", image)], minVersion: minVersion
        )
        fetcher.set(Self.manifestURL.absoluteString, manifest)
        fetcher.set(Self.manifestURL.absoluteString + ".sig", signer.signatureFile(manifest))
        fetcher.set(Self.base + "ESP32_C5_DEVKITC_1.bin", image)
    }

    // MARK: Consents

    @Test func signedLocalFilesNeedTheBoardModelAndDowngradeConsents() throws {
        let signer = TestSigner()
        let older = FirmwareReleaseFixture.image(chipID: 0x17, version: "0.1.0")
        let package = try FirmwarePackage.file(older, signature: signer.signatureFile(older), trust: signer.trust)
        #expect(package.requiredConsents(for: boardInfo(version: "0.2.0")) == [.boardModel("Test board"), .notNewer(.older)])
        #expect(package.requiredConsents(for: boardInfo(version: "0.1.0")) == [.boardModel("Test board"), .notNewer(.same)])
        #expect(package.requiredConsents(for: boardInfo(version: "0.0.9")) == [.boardModel("Test board")])

        let unsigned = try FirmwarePackage.file(older, signature: nil, trust: signer.trust)
        #expect(unsigned.requiredConsents(for: boardInfo(version: "0.0.9")) == [.unsigned, .boardModel("Test board")])
    }

    @Test func releasePackagesNeedConsentOnlyWhenNotNewerOrStale() async throws {
        let signer = TestSigner()
        let image = FirmwareReleaseFixture.image(chipID: 0x17, version: "0.2.0")
        let catalog = FirmwareCatalog(manifestURL: Self.manifestURL, trust: signer.trust, fetcher: host(signer, version: "0.2.0", image: image))
        let fresh = try await catalog.download(catalog.check(boardInfo(version: "0.1.0")), for: boardInfo(version: "0.1.0"))
        #expect(fresh.requiredConsents(for: boardInfo(version: "0.1.0")).isEmpty)
        #expect(fresh.requiredConsents(for: boardInfo(version: "0.2.0")) == [.notNewer(.same)])
        #expect(fresh.requiredConsents(for: boardInfo(version: "1.0.0")) == [.notNewer(.older)])
    }

    @Test func imageVersionMustMatchTheManifest() async throws {
        let signer = TestSigner()
        let image = FirmwareReleaseFixture.image(chipID: 0x17, version: "0.1.0")  // Listed as 0.2.0.
        let catalog = FirmwareCatalog(manifestURL: Self.manifestURL, trust: signer.trust, fetcher: host(signer, version: "0.2.0", image: image))
        let offer = try await catalog.check(boardInfo())
        await #expect(throws: FirmwareUpdateError.imageCorrupt("the image is version 0.1.0, the release says 0.2.0")) {
            try await catalog.download(offer, for: boardInfo())
        }
    }

    // MARK: Release history

    @Test func replayedOldManifestIsFlaggedAndMinVersionIsEnforced() async throws {
        let signer = TestSigner()
        let history = InMemoryFirmwareReleaseHistory()
        let v3 = FirmwareReleaseFixture.image(chipID: 0x17, version: "0.3.0")
        let fetcher = host(signer, version: "0.3.0", minVersion: "0.2.0", image: v3)
        let catalog = FirmwareCatalog(manifestURL: Self.manifestURL, trust: signer.trust, fetcher: fetcher, history: history)

        let current = try await catalog.check(boardInfo(version: "0.1.0"))
        #expect(current.newerVersionSeen == nil)
        #expect(history.load() == FirmwareReleaseRecord(highestVersion: "0.3.0", minimumVersion: "0.2.0"))

        // The host goes back to an older release that is still above the minimum: allowed, but flagged.
        let v25 = FirmwareReleaseFixture.image(chipID: 0x17, version: "0.2.5")
        publish(fetcher, signer, version: "0.2.5", image: v25)
        let stale = try await catalog.check(boardInfo(version: "0.1.0"))
        #expect(stale.newerVersionSeen == "0.3.0")
        let package = try await catalog.download(stale, for: boardInfo(version: "0.1.0"))
        #expect(package.requiredConsents(for: boardInfo(version: "0.1.0")) == [.staleRelease(newer: "0.3.0")])

        // A replayed release below the remembered minimum is refused outright.
        let v1 = FirmwareReleaseFixture.image(chipID: 0x17, version: "0.1.5")
        publish(fetcher, signer, version: "0.1.5", image: v1)
        await #expect(throws: FirmwareUpdateError.staleRelease(version: "0.1.5", minimum: "0.2.0")) {
            try await catalog.check(boardInfo(version: "0.1.0"))
        }
        #expect(history.load() == FirmwareReleaseRecord(highestVersion: "0.3.0", minimumVersion: "0.2.0"))
    }

    @Test func minVersionAboveVersionIsInvalid() {
        let signer = TestSigner()
        let image = FirmwareReleaseFixture.image(chipID: 0x17)
        #expect(throws: FirmwareUpdateError.manifestInvalid("min_version 0.3.0 above version 0.2.0")) {
            try FirmwareManifest.decode(signer.manifest(
                version: "0.2.0", images: [("ESP32_C5_DEVKITC_1", "ESP32_C5", image)], minVersion: "0.3.0"
            ))
        }
    }

    @Test func userDefaultsHistoryRoundTrips() throws {
        let defaults = try #require(UserDefaults(suiteName: "firmware-history-test-\(UUID().uuidString)"))
        let history = UserDefaultsFirmwareReleaseHistory(defaults: defaults)
        #expect(history.load() == FirmwareReleaseRecord())
        history.save(FirmwareReleaseRecord(highestVersion: "1.0.0", minimumVersion: "0.9.0"))
        #expect(UserDefaultsFirmwareReleaseHistory(defaults: defaults).load().highestVersion == "1.0.0")
    }

    // MARK: Transport limits

    @Test func httpIsRefusedUnlessAllowed() async throws {
        let signer = TestSigner()
        let insecure = URL(string: "http://releases.example.com/fw/firmware-manifest.json")!
        let catalog = FirmwareCatalog(manifestURL: insecure, trust: signer.trust, fetcher: FixtureFetcher([:]))
        await #expect(throws: FirmwareUpdateError.manifestUnavailable("the release address must use https")) {
            try await catalog.check(boardInfo())
        }

        // An https manifest that points its image at http.
        let image = FirmwareReleaseFixture.image(chipID: 0x17, version: "0.2.0")
        let entries = String(decoding: signer.manifest(version: "0.2.0", images: [("ESP32_C5_DEVKITC_1", "ESP32_C5", image)]), as: UTF8.self)
            .replacingOccurrences(of: "\"url\": \"ESP32_C5_DEVKITC_1.bin\"", with: "\"url\": \"http://cdn.example.com/a.bin\"")
        let manifest = Data(entries.utf8)
        let fetcher = FixtureFetcher([
            Self.manifestURL.absoluteString: manifest, Self.manifestURL.absoluteString + ".sig": signer.signatureFile(manifest),
        ])
        let strict = FirmwareCatalog(manifestURL: Self.manifestURL, trust: signer.trust, fetcher: fetcher)
        await #expect(throws: FirmwareUpdateError.manifestInvalid("image URL is not https")) { try await strict.check(boardInfo()) }
        let local = FirmwareCatalog(manifestURL: Self.manifestURL, trust: signer.trust, fetcher: fetcher, allowsInsecureHTTP: true)
        #expect(try await local.check(boardInfo()).imageURL.absoluteString == "http://cdn.example.com/a.bin")
    }

    @Test func signatureURLKeepsTheQuery() {
        let url = URL(string: "https://example.com/dl/firmware-manifest.json?token=abc")!
        #expect(FirmwareCatalog.signatureURL(for: url)?.absoluteString == "https://example.com/dl/firmware-manifest.json.sig?token=abc")
        #expect(FirmwareCatalog.signatureURL(for: Self.manifestURL)?.absoluteString == Self.base + "firmware-manifest.json.sig")
    }

    /// The firmware release workflow uploads `firmware-manifest.json` and its
    /// `.sig` to each GitHub release; the latest one is reached by this path.
    @Test func defaultManifestIsTheLatestFirmwareReleaseAsset() {
        let url = FirmwareCatalog.defaultManifestURL.absoluteString
        #expect(url == "https://github.com/christianrowlands/network-survey-esp32/releases/latest/download/firmware-manifest.json")
        #expect(FirmwareCatalog.signatureURL(for: FirmwareCatalog.defaultManifestURL)?.absoluteString == url + ".sig")
    }

    @Test func oversizedDownloadsAndFilesAreRefused() async throws {
        let signer = TestSigner()
        let image = FirmwareReleaseFixture.image(chipID: 0x17, version: "0.2.0")
        let fetcher = host(signer, version: "0.2.0", image: image)
        let catalog = FirmwareCatalog(manifestURL: Self.manifestURL, trust: signer.trust, fetcher: fetcher)
        let offer = try await catalog.check(boardInfo())
        fetcher.set(offer.imageURL.absoluteString, image + Data(count: 100))
        await #expect(throws: FirmwareUpdateError.imageCorrupt("larger than the release says")) {
            try await catalog.download(offer, for: boardInfo())
        }
        fetcher.set(Self.manifestURL.absoluteString, Data(count: FirmwareLimits.maxManifestBytes + 1))
        await #expect {
            try await catalog.check(boardInfo())
        } throws: { error in
            if case .manifestUnavailable = error as? FirmwareUpdateError { return true }
            return false
        }
        // A manifest entry over the image limit.
        let big = String(decoding: signer.manifest(version: "0.2.0", images: [("ESP32_C5_DEVKITC_1", "ESP32_C5", image)]), as: UTF8.self)
            .replacingOccurrences(of: "\"size\": \(image.count)", with: "\"size\": \(FirmwareLimits.maxImageBytes + 1)")
        #expect(throws: FirmwareUpdateError.self) { try FirmwareManifest.decode(Data(big.utf8)) }
        // A local file over the limit.
        let huge = FirmwareReleaseFixture.image(chipID: 0x17, size: FirmwareLimits.maxImageBytes + 1)
        #expect(throws: FirmwareUpdateError.imageTooLarge) { _ = try FirmwarePackage.file(huge, signature: nil, trust: signer.trust) }
    }

    @Test func fetchErrorsReadWell() {
        #expect(FirmwareFetchError.http(404).localizedDescription == "HTTP 404")
        #expect(FirmwareFetchError.tooLarge(limit: 1024).localizedDescription.contains("limit"))
    }

    // MARK: Strict versions

    @Test func strictSemanticVersions() {
        for bad in ["01.2.3", "1.02.3", "+1.2.3", "1.2.3-01", "1.2.3-a_b", "1.2.+3", " 1.2.3x"] {
            #expect(FirmwareVersion(bad) == nil, "\(bad)")
        }
        #expect(FirmwareVersion("1.2.3-0") != nil)
        #expect(FirmwareVersion("1.2.3-x-y.0a") != nil)
        let huge = "1.0.0-99999999999999999999999"
        #expect(FirmwareVersion(huge)! > FirmwareVersion("1.0.0-99999999999999999999998")!)
        #expect(FirmwareVersion(huge)! < FirmwareVersion("1.0.0-alpha")!)
        #expect(FirmwareVersion("1.0.0-9")! < FirmwareVersion("1.0.0-10")!)
    }

    #if DEBUG
    @Test func developmentKeyExistsOnlyInDebug() {
        #expect(FirmwareTrust.developmentKey.isDevelopment)
        #expect(!FirmwareTrust.release.keys.contains(FirmwareTrust.developmentKey))
    }
    #endif
}
