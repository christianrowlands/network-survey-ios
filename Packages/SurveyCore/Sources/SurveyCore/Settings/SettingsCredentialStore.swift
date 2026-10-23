import Destinations
import Foundation

/// The NS Analytics registration kept in settings: the device token in the
/// Keychain, the endpoint and workspace in the `ns_analytics_*` keys, so the
/// Settings screen can observe them like any other setting.
public struct SettingsCredentialStore: NSAnalyticsCredentialStore {
    public let settings: SettingsStore
    /// The install ID the registration was made with.
    public let deviceID: String

    public init(settings: SettingsStore, deviceID: String) {
        self.settings = settings
        self.deviceID = deviceID
    }

    /// Nil unless both the token and the endpoint are present.
    public func load() -> NSAnalyticsRegistration? {
        guard let token = settings.secret(Secrets.nsAnalyticsDeviceToken),
              let url = URL(string: settings[Settings.nsAnalyticsAPIURL]), url.scheme != nil else { return nil }
        let name = settings[Settings.nsAnalyticsWorkspaceName]
        return NSAnalyticsRegistration(
            deviceToken: token, deviceID: deviceID, workspaceID: settings[Settings.nsAnalyticsWorkspaceID],
            workspaceName: name.isEmpty ? nil : name, apiURL: url
        )
    }

    public func save(_ registration: NSAnalyticsRegistration) {
        // If the Keychain refuses, load() stays nil and the UI shows "not registered".
        try? settings.setSecret(registration.deviceToken, for: Secrets.nsAnalyticsDeviceToken)
        settings[Settings.nsAnalyticsAPIURL] = registration.apiURL.absoluteString
        settings[Settings.nsAnalyticsWorkspaceID] = registration.workspaceID
        settings[Settings.nsAnalyticsWorkspaceName] = registration.workspaceName ?? ""
    }

    public func clear() {
        try? settings.setSecret(nil, for: Secrets.nsAnalyticsDeviceToken)
        settings[Settings.nsAnalyticsAPIURL] = ""
        settings[Settings.nsAnalyticsWorkspaceID] = ""
        settings[Settings.nsAnalyticsWorkspaceName] = ""
    }
}
