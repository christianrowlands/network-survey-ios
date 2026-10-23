import Destinations
import Foundation
import Security
import Testing
@testable import SurveyCore

@Suite("Settings")
struct SettingsTests {
    @Test("Defaults: Wi-Fi on, BLE and raw frames off, files on, other destinations off")
    func defaults() {
        let settings = SettingsStore.inMemory()
        #expect(settings[Settings.surveyWifiAP])
        #expect(settings[Settings.surveyWifiClient])
        #expect(!settings[Settings.surveyBLE])
        #expect(!settings[Settings.surveyRawFrames])
        #expect(settings[Settings.destinationLogFiles])
        #expect(!settings[Settings.destinationMQTT])
        #expect(!settings[Settings.destinationGRPC])
        #expect(!settings[Settings.destinationNSAnalytics])
        #expect(!settings[Settings.mqttStreamClientRecords])
        #expect(!settings[Settings.nsAnalyticsUploadProbeRecords])
        #expect(settings[Settings.streamingQueueLimit] == 20_000)
        #expect(settings[Settings.deviceStatusIntervalSeconds] == 120)
        #expect(settings[Settings.privacyZones].isEmpty)
        #expect(settings[Settings.ignoreList].isEmpty)
        #expect(settings[Settings.locationSource] == .phone)
        #expect(settings[Settings.grpcPort] == 2621)
        #expect(settings[Settings.nsAnalyticsUploadIntervalMinutes] == 15)
        let plan = SurveyPlan(settings: settings)
        #expect(plan == SurveyPlan())
    }

    @Test("Values round trip and reset to the default")
    func roundTrip() {
        let settings = SettingsStore.inMemory()
        settings[Settings.surveyBLE] = true
        settings[Settings.mqttPort] = 1883
        settings[Settings.mqttHost] = "broker.example.com"
        settings[Settings.units] = .imperial
        #expect(settings[Settings.surveyBLE])
        #expect(settings[Settings.mqttPort] == 1883)
        #expect(settings[Settings.mqttHost] == "broker.example.com")
        #expect(settings[Settings.units] == .imperial)
        settings.reset(Settings.mqttPort)
        #expect(settings[Settings.mqttPort] == 8883)
    }

    @Test("Values written by UserDefaults read back typed")
    func userDefaultsBackend() throws {
        let suite = "SurveyCoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(backend: UserDefaultsBackend(defaults), keychain: InMemoryKeychain())
        settings[Settings.streamingQueueLimit] = 0
        settings[Settings.locationSource] = .board
        #expect(defaults.integer(forKey: "streaming_queue_limit") == 0)
        #expect(defaults.string(forKey: "location_provider") == "board")
        // A managed value of the wrong type falls back to the default.
        defaults.set("not a number", forKey: "mqtt_connection_port")
        #expect(settings[Settings.mqttPort] == 8883)
    }

    @Test("Secrets live in the keychain, not in defaults")
    func secrets() throws {
        let backend = InMemorySettingsBackend()
        let keychain = InMemoryKeychain()
        let settings = SettingsStore(backend: backend, keychain: keychain)
        try settings.setSecret("s3cret", for: Secrets.mqttPassword)
        #expect(settings.secret(Secrets.mqttPassword) == "s3cret")
        #expect(try keychain.read("mqtt_password") == "s3cret")
        #expect(backend.object(forKey: "mqtt_password") == nil)
        try settings.setSecret(nil, for: Secrets.mqttPassword)
        #expect(settings.secret(Secrets.mqttPassword) == nil)
    }

    @Test("Install ID is created once and reused; device name falls back to a per-install default")
    func identity() {
        let settings = SettingsStore.inMemory()
        let first = DeviceIdentity.load(from: settings, deviceModel: "iPhone17,3")
        let second = DeviceIdentity.load(from: settings, deviceModel: "iPhone17,3")
        #expect(first.installID == second.installID)
        #expect(first.deviceSerialNumber == DeviceIdentity.shortID(first.installID))
        #expect(first.deviceName == DeviceIdentity.defaultName(installID: first.installID))
        #expect(DeviceIdentity.defaultName(installID: Fixtures.installID) == "iPhone-0000")
        #expect(DeviceIdentity.defaultName(installID: UUID(uuidString: "12fe0000-0000-4000-8000-000000000001")!) == "iPhone-12FE")
        settings[Settings.deviceName] = "  Van 2 "
        #expect(DeviceIdentity.load(from: settings, deviceModel: "iPhone17,3").deviceName == "Van 2")
        #expect(!DeviceModel.identifier().isEmpty)
    }

    @Test("Changes are announced by key name")
    func changes() async {
        let settings = SettingsStore.inMemory()
        let changes = settings.changes()
        settings[Settings.surveyBLE] = true
        try? settings.setSecret("x", for: Secrets.nsAnalyticsDeviceToken)
        var names: [String] = []
        for await name in changes {
            names.append(name)
            if names.count == 2 { break }
        }
        #expect(names == ["survey_ble", "ns_analytics_device_token"])
    }

    #if os(macOS)
    // Reads the repo docs from the host file system, which the iOS simulator does not see.
    @Test("Every key name is unique and documented")
    func keyNamesDocumented() throws {
        let names = Settings.allKeyNames + Secrets.all.map(\.name)
        #expect(Set(names).count == names.count)
        let docs = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/settings-keys.md")
        let text = try String(contentsOf: docs, encoding: .utf8)
        for name in names {
            #expect(text.contains("`\(name)`"), "\(name) missing from docs/settings-keys.md")
        }
    }
    #endif

    @Test("NS Analytics registration lives in settings and the keychain")
    func credentialStore() throws {
        let keychain = InMemoryKeychain()
        let settings = SettingsStore(backend: InMemorySettingsBackend(), keychain: keychain)
        let store = SettingsCredentialStore(settings: settings, deviceID: Fixtures.installID.uuidString)
        #expect(store.load() == nil)
        let registration = NSAnalyticsRegistration(
            deviceToken: "token-1", deviceID: Fixtures.installID.uuidString, workspaceID: "ws-1",
            workspaceName: "Example Workspace", apiURL: try #require(URL(string: "https://upload.example.com/api"))
        )
        store.save(registration)
        #expect(store.load() == registration)
        #expect(try keychain.read("ns_analytics_device_token") == "token-1")
        #expect(settings[Settings.nsAnalyticsWorkspaceID] == "ws-1")
        store.clear()
        #expect(store.load() == nil)
        #expect(settings[Settings.nsAnalyticsAPIURL].isEmpty)
        #expect(settings.secret(Secrets.nsAnalyticsDeviceToken) == nil)
    }

    @Test("Managed values may be strings; out-of-range values read as the default")
    func lenientValues() {
        let backend = InMemorySettingsBackend()
        let settings = SettingsStore(backend: backend, keychain: InMemoryKeychain())
        backend.set("1883", forKey: "mqtt_connection_port")
        backend.set("false", forKey: "mqtt_tls_enabled")
        backend.set("YES", forKey: "survey_ble")
        #expect(settings[Settings.mqttPort] == 1883)
        #expect(!settings[Settings.mqttTLSEnabled])
        #expect(settings[Settings.surveyBLE])
        backend.set(70_000, forKey: "mqtt_connection_port")
        backend.set(-1, forKey: "streaming_queue_limit")
        backend.set(5, forKey: "device_status_scan_interval_seconds")
        #expect(settings[Settings.mqttPort] == 8883)
        #expect(settings[Settings.streamingQueueLimit] == 20_000)
        #expect(settings[Settings.deviceStatusIntervalSeconds] == 120)
        backend.set(0, forKey: "streaming_queue_limit")
        #expect(settings[Settings.streamingQueueLimit] == 0)
    }

    @Test("A Keychain read error never replaces the install ID")
    func installIDReadError() throws {
        let keychain = FailingKeychain()
        let settings = SettingsStore(backend: InMemorySettingsBackend(), keychain: keychain)
        try keychain.inner.write("00000000-0000-4000-8000-0000000000AA", for: "install_id")
        keychain.failing = true
        let temporary = DeviceIdentity.load(from: settings, deviceModel: "iPhone17,3")
        #expect(temporary.installID.uuidString != "00000000-0000-4000-8000-0000000000AA")
        keychain.failing = false
        #expect(try keychain.inner.read("install_id") == "00000000-0000-4000-8000-0000000000AA")
        let real = DeviceIdentity.load(from: settings, deviceModel: "iPhone17,3")
        #expect(real.installID.uuidString == "00000000-0000-4000-8000-0000000000AA")
    }

    @Test("A fresh install clears old credentials but keeps the install ID")
    func freshInstall() throws {
        let keychain = InMemoryKeychain()
        try keychain.write("old-password", for: "mqtt_password")
        try keychain.write("00000000-0000-4000-8000-0000000000AA", for: "install_id")
        let settings = SettingsStore(backend: InMemorySettingsBackend(), keychain: keychain)
        let identity = DeviceIdentity.load(from: settings, deviceModel: "iPhone17,3")
        #expect(identity.installID.uuidString == "00000000-0000-4000-8000-0000000000AA")
        #expect(settings.secret(Secrets.mqttPassword) == nil)
        try settings.setSecret("new-password", for: Secrets.mqttPassword)
        #expect(!settings.clearStaleCredentialsOnFreshInstall())
        #expect(settings.secret(Secrets.mqttPassword) == "new-password")
    }
}

/// A Keychain that can be made to fail like a locked device.
final class FailingKeychain: KeychainStore, @unchecked Sendable {
    let inner = InMemoryKeychain()
    var failing = false

    func read(_ name: String) throws -> String? {
        if failing { throw KeychainError(status: errSecInteractionNotAllowed) }
        return try inner.read(name)
    }

    func write(_ value: String, for name: String) throws {
        if failing { throw KeychainError(status: errSecInteractionNotAllowed) }
        try inner.write(value, for: name)
    }

    func delete(_ name: String) throws {
        if failing { throw KeychainError(status: errSecInteractionNotAllowed) }
        try inner.delete(name)
    }
}
