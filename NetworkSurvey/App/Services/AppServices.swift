import BoardKit
import Destinations
import Foundation
import SurveyCore
import UIKit

/// The phone's battery level for DeviceStatus records.
nonisolated struct DeviceBattery: BatteryProvider {
    func batteryLevel() async -> Double? {
        await MainActor.run {
            UIDevice.current.isBatteryMonitoringEnabled = true
            let level = UIDevice.current.batteryLevel
            return level < 0 ? nil : Double(level)
        }
    }
}

/// Builds the destinations of one survey session from the settings, as the
/// session plan turned them on.
///
/// Made-up demo data never reaches NS Analytics: a session that starts with a
/// demo board has no NS Analytics destination, and records from a demo board
/// that joins later are dropped before it. Files, MQTT and gRPC still take
/// demo data, so people can try their own broker or server.
nonisolated enum DestinationFactory {
    static func make(
        _ context: SessionContext, settings: SettingsStore, uploader: NSAnalyticsUploader,
        demoBoards: Set<String> = [], startsWithDemo: Bool = false
    ) -> [any SurveyRecordSink] {
        let plan = context.plan
        var destinations: [any Destination] = []
        if plan.logFiles {
            destinations.append(NSCSVDestination())
            if settings[Settings.logWigleCSV] { destinations.append(WiGLEDestination()) }
            if plan.rawFrames { destinations.append(PcapDestination()) }
        }
        if plan.mqtt {
            let clientID = settings[Settings.mqttClientID].trimmingCharacters(in: .whitespaces)
            let username = settings[Settings.mqttUsername]
            destinations.append(MQTTDestination(config: MQTTConfig(
                host: settings[Settings.mqttHost], port: settings[Settings.mqttPort],
                useTLS: settings[Settings.mqttTLSEnabled], username: username.isEmpty ? nil : username,
                password: settings.secret(Secrets.mqttPassword),
                clientID: clientID.isEmpty ? defaultClientID(context) : clientID,
                topicPrefix: settings[Settings.mqttTopicPrefix], queueLimit: settings[Settings.streamingQueueLimit],
                streamStationRecords: settings[Settings.mqttStreamClientRecords]
            )))
        }
        if plan.grpc {
            destinations.append(GRPCDestination(config: GRPCConfig(
                host: settings[Settings.grpcHost], port: settings[Settings.grpcPort],
                useTLS: settings[Settings.grpcTLSEnabled], queueLimit: settings[Settings.streamingQueueLimit]
            )))
        }
        if plan.nsAnalytics && !startsWithDemo {
            let minutes = settings[Settings.nsAnalyticsUploadIntervalMinutes]
            let upload = NSAnalyticsDestination(uploader: uploader, config: NSAnalyticsConfig(
                uploadInterval: minutes > 0 ? .seconds(minutes * 60) : nil,
                uploadProbeRequests: settings[Settings.nsAnalyticsUploadProbeRecords],
                uploadStationRecords: settings[Settings.nsAnalyticsUploadClientRecords]
            ))
            destinations.append(RealBoardsOnly(upload, demoBoards: demoBoards))
        }
        return destinations.isEmpty ? [] : [DestinationHub(destinations)]
    }

    /// "ns-ios-" plus the start of the install ID, stable for this install.
    static func defaultClientID(_ context: SessionContext) -> String {
        "ns-ios-" + context.deviceSerialNumber.prefix(8).lowercased()
    }
}

/// Passes records on except those from demo boards.
actor RealBoardsOnly: Destination {
    nonisolated let kind: DestinationKind
    private let inner: any Destination
    private let demoBoards: Set<String>

    init(_ inner: any Destination, demoBoards: Set<String>) {
        kind = inner.kind
        self.inner = inner
        self.demoBoards = demoBoards
    }

    func start(_ session: SessionInfo) async throws {
        try await inner.start(session)
    }

    func accept(_ records: [SurveyRecord]) async {
        let real = records.filter { !demoBoards.contains($0.boardID) }
        if !real.isEmpty { await inner.accept(real) }
    }

    func stop() async {
        await inner.stop()
    }

    func snapshot() async -> DestinationSnapshot {
        await inner.snapshot()
    }
}

/// The role the user picked for each board, kept across launches. BoardKit
/// holds roles only in memory.
struct BoardRoleStore {
    static let key = "board_roles"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load() -> [BoardID: BoardRolePreference] {
        guard let data = defaults.data(forKey: Self.key),
              let stored = try? JSONDecoder().decode([String: BoardRolePreference].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: stored.map { key, role in (BoardID(rawValue: key), role) })
    }

    func save(_ role: BoardRolePreference?, for board: BoardID) {
        var stored = load()
        stored[board] = role == .auto ? nil : role
        let encoded = Dictionary(uniqueKeysWithValues: stored.map { ($0.key.description, $0.value) })
        defaults.set(try? JSONEncoder().encode(encoded), forKey: Self.key)
    }
}

/// Keeps the screen awake while any reason holds it (a survey on screen, a
/// firmware update in progress).
@MainActor
final class IdleTimerController {
    private var reasons: Set<String> = []

    func hold(_ reason: String) {
        reasons.insert(reason)
        apply()
    }

    func release(_ reason: String) {
        reasons.remove(reason)
        apply()
    }

    func set(_ reason: String, held: Bool) {
        held ? hold(reason) : release(reason)
    }

    private func apply() {
        UIApplication.shared.isIdleTimerDisabled = !reasons.isEmpty
    }
}
