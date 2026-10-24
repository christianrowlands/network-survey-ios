import Foundation

/// Every setting the app stores, with its default (see docs/settings-keys.md):
/// Wi-Fi APs and clients on, BLE and raw frames off, file logging on, every
/// other destination off until configured, privacy lists empty.
public enum Settings {
    // MARK: What to survey
    public static let surveyWifiAP = SettingKey<Bool>("survey_wifi_ap", default: true)
    /// Client (station) and probe request observations.
    public static let surveyWifiClient = SettingKey<Bool>("survey_wifi_client", default: true)
    public static let surveyBLE = SettingKey<Bool>("survey_ble", default: false)
    /// Raw 802.11 frames for pcapng.
    public static let surveyRawFrames = SettingKey<Bool>("survey_raw_frames", default: false)

    // MARK: Where the data goes
    public static let destinationLogFiles = SettingKey<Bool>("destination_log_files", default: true)
    public static let destinationMQTT = SettingKey<Bool>("destination_mqtt", default: false)
    public static let destinationGRPC = SettingKey<Bool>("destination_grpc", default: false)
    public static let destinationNSAnalytics = SettingKey<Bool>("destination_ns_analytics", default: false)

    // MARK: MQTT
    public static let mqttHost = SettingKey<String>("mqtt_connection_host", default: "")
    public static let mqttPort = SettingKey<Int>("mqtt_connection_port", default: 8883, range: 1...65535)
    public static let mqttTLSEnabled = SettingKey<Bool>("mqtt_tls_enabled", default: true)
    /// Empty means the app picks a client ID.
    public static let mqttClientID = SettingKey<String>("mqtt_client_id", default: "")
    public static let mqttUsername = SettingKey<String>("mqtt_username", default: "")
    public static let mqttTopicPrefix = SettingKey<String>("mqtt_topic_prefix", default: "")
    /// Records held while a stream is disconnected; 0 means unbounded.
    public static let streamingQueueLimit = SettingKey<Int>("streaming_queue_limit", default: 20_000, range: 0...Int.max)
    /// Experimental: stream station (client) records on the proposed topic.
    public static let mqttStreamClientRecords = SettingKey<Bool>("mqtt_stream_client_records", default: false)

    // MARK: gRPC
    public static let grpcHost = SettingKey<String>("grpc_connection_host", default: "")
    public static let grpcPort = SettingKey<Int>("grpc_connection_port", default: 2621, range: 1...65535)
    public static let grpcTLSEnabled = SettingKey<Bool>("grpc_tls_enabled", default: false)

    // MARK: NS Analytics
    /// Upload endpoint from the registration QR code or link.
    public static let nsAnalyticsAPIURL = SettingKey<String>("ns_analytics_api_url", default: "")
    public static let nsAnalyticsWorkspaceID = SettingKey<String>("ns_analytics_workspace_id", default: "")
    public static let nsAnalyticsWorkspaceName = SettingKey<String>("ns_analytics_workspace_name", default: "")
    /// Minutes between uploads while surveying; 0 means only when the survey stops.
    public static let nsAnalyticsUploadIntervalMinutes = SettingKey<Int>("ns_analytics_upload_interval_minutes", default: 15, range: 0...1440)
    /// Experimental: upload probe request records (the backend skips them today).
    public static let nsAnalyticsUploadProbeRecords = SettingKey<Bool>("ns_analytics_upload_probe_records", default: false)
    /// Experimental: upload station (client) records.
    public static let nsAnalyticsUploadClientRecords = SettingKey<Bool>("ns_analytics_upload_client_records", default: false)

    // MARK: Device
    /// Empty means the device model.
    public static let deviceName = SettingKey<String>("device_name", default: "")
    public static let deviceStatusIntervalSeconds = SettingKey<Int>("device_status_scan_interval_seconds", default: 120, range: 10...86_400)

    // MARK: Location and display
    public static let locationSource = SettingKey<LocationSourcePreference>.enumeration("location_provider", default: .phone)
    public static let units = SettingKey<DisplayUnits>.enumeration("display_units", default: .metric)

    // MARK: Privacy
    public static let privacyZones = SettingKey<[PrivacyZone]>.json("privacy_zones", default: [])
    public static let ignoreList = SettingKey<[IgnoreEntry]>.json("ignore_list", default: [])
    /// Send crash and hang reports, in builds configured with a crash reporting DSN.
    public static let crashReports = SettingKey<Bool>("send_crash_reports", default: true)

    // MARK: Advanced
    /// Show the simulated "Demo board" in the board list.
    public static let demoBoardEnabled = SettingKey<Bool>("demo_board_enabled", default: false)
    /// The first-launch welcome was shown and closed.
    public static let hasSeenWelcome = SettingKey<Bool>("has_seen_welcome", default: false)

    /// Every plain setting's name, for docs and a future managed configuration layer.
    public static let allKeyNames = [
        surveyWifiAP.name, surveyWifiClient.name, surveyBLE.name, surveyRawFrames.name,
        destinationLogFiles.name, destinationMQTT.name, destinationGRPC.name, destinationNSAnalytics.name,
        mqttHost.name, mqttPort.name, mqttTLSEnabled.name, mqttClientID.name,
        mqttUsername.name, mqttTopicPrefix.name, streamingQueueLimit.name, mqttStreamClientRecords.name,
        grpcHost.name, grpcPort.name, grpcTLSEnabled.name, nsAnalyticsAPIURL.name,
        nsAnalyticsWorkspaceID.name, nsAnalyticsWorkspaceName.name, nsAnalyticsUploadIntervalMinutes.name,
        nsAnalyticsUploadProbeRecords.name, nsAnalyticsUploadClientRecords.name,
        deviceName.name, deviceStatusIntervalSeconds.name, locationSource.name, units.name, privacyZones.name,
        ignoreList.name, crashReports.name, demoBoardEnabled.name, hasSeenWelcome.name,
    ]
}

/// Keychain items. Readable after first unlock so a locked phone can keep
/// streaming during a survey.
public enum Secrets {
    public static let mqttPassword = SecretKey("mqtt_password")
    public static let grpcAuthToken = SecretKey("grpc_auth_token")
    public static let nsAnalyticsDeviceToken = SecretKey("ns_analytics_device_token")
    /// The per-install UUID used as deviceSerialNumber.
    public static let installID = SecretKey("install_id")

    public static let all = [mqttPassword, grpcAuthToken, nsAnalyticsDeviceToken, installID]

    /// Credentials, cleared on a fresh install (Keychain items outlive app deletion).
    public static let credentials = [mqttPassword, grpcAuthToken, nsAnalyticsDeviceToken]
}

/// Which position stamps records when both the phone and a board GPS have one.
public enum LocationSourcePreference: String, Sendable, Codable, CaseIterable {
    /// Phone location; a board GPS fix only when the phone fix is missing or stale.
    case phone
    /// Board GPS; the phone location only when no board has a fresh fix.
    case board
}

public enum DisplayUnits: String, Sendable, Codable, CaseIterable {
    case metric
    case imperial
}
