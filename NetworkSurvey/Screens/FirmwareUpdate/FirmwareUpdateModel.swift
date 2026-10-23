import BoardKit
import BoardProtocol
import Foundation
import Observation

/// Drives the firmware update screen: check the signed release manifest or
/// read a file, verify, then install over Bluetooth.
@MainActor
@Observable
final class FirmwareUpdateModel {
    enum Stage: Equatable {
        case start
        case checking
        /// A verified release manifest has an image for this board.
        case offer(FirmwareOffer)
        case downloading(FirmwareOffer)
        /// A verified package waiting for the user to start the install.
        case ready(FirmwarePackage)
        case installing(FirmwareInstallPhase)
        case done(FirmwareInstallResult)
        case failed(FirmwareUpdateError)
    }

    /// The manifest URL can be pointed elsewhere for testing (a local server).
    static let manifestURLDefaultsKey = "NSFirmwareManifestURL"

    /// Debug builds also trust the development key; Release builds only the release keys.
    static var trust: FirmwareTrust {
        #if DEBUG
        .development
        #else
        .release
        #endif
    }

    let boardID: BoardID
    private let manager: BoardManager
    let isDemo: Bool
    private let catalog: FirmwareCatalog
    private(set) var stage: Stage = .start
    /// What the user explicitly accepted for the package on screen.
    var accepted: Set<FirmwareConsent> = []
    /// The app went to the background during the install.
    private(set) var leftForeground = false
    /// The package of the last install, so an interrupted one can resume.
    private(set) var lastPackage: FirmwarePackage?
    @ObservationIgnored private var installTask: Task<Void, Never>?

    init(boardID: BoardID, manager: BoardManager, isDemo: Bool, defaults: UserDefaults = .standard) {
        self.boardID = boardID
        self.manager = manager
        self.isDemo = isDemo
        catalog = Self.catalog(defaults: defaults)
    }

    /// Official releases, with this build's trust and manifest URL.
    static func catalog(defaults: UserDefaults = .standard) -> FirmwareCatalog {
        let url = defaults.string(forKey: Self.manifestURLDefaultsKey).flatMap(URL.init(string:))
        #if DEBUG
        let allowsHTTP = true  // A local test server; ATS still needs an exception for it.
        #else
        let allowsHTTP = false
        #endif
        return FirmwareCatalog(
            manifestURL: url ?? FirmwareCatalog.defaultManifestURL, trust: Self.trust,
            history: UserDefaultsFirmwareReleaseHistory(defaults: defaults), allowsInsecureHTTP: allowsHTTP
        )
    }

    /// How the board's firmware compares with the latest release, for the
    /// Board page. Nil when that can't be checked (offline, no release for this
    /// board, no verified manifest).
    static func releaseStatus(for info: NSBBoardInfo) async -> String? {
        guard let offer = try? await catalog().check(info) else { return nil }
        return releaseStatus(offer.comparison, latest: offer.version)
    }

    static func releaseStatus(_ comparison: FirmwareComparison, latest: String) -> String? {
        switch comparison {
        case .newer: "Update available (\(latest))"
        case .same: "Up to date"
        case .older: "Newer than the latest release"
        case .unknown: nil
        }
    }

    var board: BoardManager.BoardState? { manager.boards[boardID] }
    var info: NSBBoardInfo? { board?.info }
    var isInstalling: Bool {
        if case .installing = stage { true } else { false }
    }

    /// Cancel is offered only before OtaEnd: after it the board may already
    /// switch to the new image, and an abort can no longer stop that.
    var canCancel: Bool {
        switch stage {
        case .installing(.connecting), .installing(.transferring), .installing(.reconnecting): true
        default: false
        }
    }

    func consents(for package: FirmwarePackage) -> [FirmwareConsent] {
        info.map(package.requiredConsents(for:)) ?? []
    }

    func isAccepted(_ package: FirmwarePackage) -> Bool {
        Set(consents(for: package)).isSubset(of: accepted)
    }

    /// Why an update cannot start now, for the user; nil when it can.
    var blocker: String? {
        if isDemo { return "The demo Scout is simulated and has no firmware to update." }
        if manager.capture != nil { return FirmwareUpdateError.surveyRunning.userMessage }
        if board?.connection.isConnected != true { return "Connect the Scout first." }
        return nil
    }

    // MARK: - Actions

    func check() async {
        guard blocker == nil, let info else { return }
        stage = .checking
        do {
            stage = .offer(try await catalog.check(info))
        } catch {
            stage = .failed(error)
        }
    }

    func downloadAndInstall(_ offer: FirmwareOffer) async {
        guard let info else { return }
        stage = .downloading(offer)
        do {
            let package = try await catalog.download(offer, for: info)
            accepted = []
            if consents(for: package).isEmpty {
                install(package)
            } else {
                stage = .ready(package)
            }
        } catch {
            stage = .failed(error)
        }
    }

    /// Reads an image the user picked, plus its `.sig` file when one was picked too.
    func loadFile(urls: [URL]) {
        let images = urls.filter { $0.pathExtension.lowercased() != "sig" }
        let signatures = urls.filter { $0.pathExtension.lowercased() == "sig" }
        guard images.count == 1, signatures.count <= 1, let image = images.first else {
            stage = .failed(.fileChoice)
            return
        }
        do {
            let data = try Self.read(image, maxBytes: FirmwareLimits.maxImageBytes)
            let signature = try signatures.first.map { try Self.read($0, maxBytes: FirmwareLimits.maxManifestBytes) }
            let package = try FirmwarePackage.file(data, signature: signature, trust: Self.trust)
            if let info { try package.checkCompatible(with: info) }
            accepted = []
            stage = .ready(package)
        } catch let error as FirmwareUpdateError {
            stage = .failed(error)
        } catch {
            stage = .failed(.downloadFailed(error.localizedDescription))
        }
    }

    func install(_ package: FirmwarePackage) {
        guard blocker == nil, !isInstalling else { return }
        guard isAccepted(package) else { return }
        leftForeground = false
        lastPackage = package
        stage = .installing(.connecting)
        let installer = FirmwareInstaller(
            transport: manager.transport, board: boardID, package: package, appVersion: manager.appVersion,
            coordinator: manager
        )
        // Phases arrive on the installer's actor; a stream keeps them in order.
        let (phases, sink) = AsyncStream.makeStream(of: FirmwareInstallPhase.self, bufferingPolicy: .bufferingNewest(1))
        let follower = Task { [weak self] in
            for await phase in phases {
                self?.progress(phase)
            }
        }
        installTask = Task { [weak self] in
            let outcome: Result<FirmwareInstallResult, FirmwareUpdateError>
            do throws(FirmwareUpdateError) {
                outcome = .success(try await installer.run { sink.yield($0) })
            } catch {
                outcome = .failure(error)
            }
            sink.finish()
            await follower.value
            switch outcome {
            case .success(let result): self?.stage = .done(result)
            case .failure(let error): self?.stage = .failed(error)
            }
        }
    }

    func cancel() {
        guard canCancel else { return }
        installTask?.cancel()
    }

    func reset() {
        stage = .start
        accepted = []
    }

    func noteBackground() {
        if isInstalling { leftForeground = true }
    }

    private func progress(_ phase: FirmwareInstallPhase) {
        guard isInstalling else { return }
        stage = .installing(phase)
    }

    /// Reads a picked file, refusing one over `maxBytes` before loading it.
    private static func read(_ url: URL, maxBytes: Int) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= maxBytes else { throw FirmwareUpdateError.imageTooLarge }
        return try Data(contentsOf: url)
    }
}
