import Destinations
import Foundation
import Observation
import SurveyCore

/// Registers this phone with an NS Analytics workspace from a QR code, a
/// pasted link or a universal link, and unregisters it.
@Observable
final class RegistrationModel {
    enum Phase: Equatable {
        case idle
        case registering
        case failed(String)
        case registered
    }

    /// A link waiting for the user to confirm, from any of the three paths.
    var pendingLink: NSAnalyticsLink?
    var phase = Phase.idle
    /// A problem with a link that was scanned, pasted or opened.
    var linkError: String?
    /// While the scan sheet is up it shows links itself.
    var isScanning = false

    @ObservationIgnored private let client: NSAnalyticsClient
    @ObservationIgnored private let credentials: any NSAnalyticsCredentialStore
    @ObservationIgnored private let settings: SettingsModel
    @ObservationIgnored private let device: @MainActor () -> NSAnalyticsClient.DeviceInfo

    init(
        client: NSAnalyticsClient, credentials: any NSAnalyticsCredentialStore, settings: SettingsModel,
        device: @escaping @MainActor () -> NSAnalyticsClient.DeviceInfo
    ) {
        self.client = client
        self.credentials = credentials
        self.settings = settings
        self.device = device
    }

    /// The current registration. The uploader can drop it (for example when the
    /// workspace removes the phone), so it is read fresh on every settings change.
    var registration: NSAnalyticsRegistration? {
        _ = settings.revision
        return credentials.load()
    }

    /// Accepts text from a QR code, the clipboard or a universal link.
    /// Returns false (and sets `linkError`) when it is not a usable link.
    @discardableResult
    func receive(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            linkError = Self.message(for: .notARegistrationLink)
            return false
        }
        return receive(url)
    }

    @discardableResult
    func receive(_ url: URL) -> Bool {
        do {
            pendingLink = try NSAnalyticsLink(url: url)
            linkError = nil
            phase = .idle
            return true
        } catch {
            linkError = Self.message(for: error)
            return false
        }
    }

    func register(_ link: NSAnalyticsLink) async {
        phase = .registering
        do {
            let registration = try await client.register(link, device: device())
            credentials.save(registration)
            settings[Settings.destinationNSAnalytics] = true
            // The link stays pending so the sheet can show the result; the
            // sheet clears it when the user taps Done.
            phase = .registered
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    /// The scan sheet opened: start fresh instead of showing the last attempt.
    func beginScanning() {
        isScanning = true
        linkError = nil
        phase = .idle
    }

    /// The scan sheet closed (Done, Cancel or a swipe). Clears the link first
    /// so the universal-link sheet does not pick it up.
    func endScanning() {
        pendingLink = nil
        isScanning = false
    }

    /// Tells the server, then forgets the registration on this phone either
    /// way. Returns false when the server could not be told.
    func unregister() async -> Bool {
        guard let registration else { return true }
        let confirmed = await client.unregister(registration)
        credentials.clear()
        settings[Settings.destinationNSAnalytics] = false
        phase = .idle
        return confirmed
    }

    static func message(for error: NSAnalyticsRegistrationError) -> String {
        switch error {
        case .network: "Could not reach NS Analytics. Check the connection and try again."
        case .codeRejected: "This registration code is invalid, expired or already used. Ask a workspace admin for a new one."
        case .deviceLimit: "The workspace has reached its device limit. Ask a workspace admin to free a slot."
        case .license: "The workspace license has expired."
        case .server: "NS Analytics had a problem. Try again in a few minutes."
        case .other(let message): message.map { "Registration failed: \($0)" } ?? "Registration failed."
        }
    }

    static func message(for problem: NSAnalyticsLink.Problem) -> String {
        switch problem {
        case .notARegistrationLink: "This is not an NS Analytics registration link."
        case .missingToken, .missingWorkspace, .missingServer:
            "This registration link is incomplete. Ask a workspace admin for a new one."
        case .serverNotHTTPS, .badServer, .localServer, .serverTooLong:
            "This registration link points to a server the app cannot use."
        case .nameTooLong: "This registration link has a workspace name that is too long."
        }
    }
}
