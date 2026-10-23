import Destinations
import Foundation
import SurveyCore
import SwiftUI

/// What a survey can record, as the Survey screen offers it.
enum SurveyProtocol: CaseIterable, Identifiable {
    case wifiAP, wifiClient, ble, rawFrames

    var id: Self { self }

    var title: String {
        switch self {
        case .wifiAP: "Wi-Fi APs"
        case .wifiClient: "Wi-Fi Clients"
        case .ble: "BLE"
        case .rawFrames: "Raw frames"
        }
    }

    var detail: String {
        switch self {
        case .wifiAP: "Access points and their beacons"
        case .wifiClient: "Devices and their probe requests"
        case .ble: "Bluetooth Low Energy adverts"
        case .rawFrames: "802.11 frames, saved as pcapng"
        }
    }

    var symbol: String {
        switch self {
        case .wifiAP: "wifi.router"
        case .wifiClient: "iphone.radiowaves.left.and.right"
        case .ble: "dot.radiowaves.right"
        case .rawFrames: "waveform"
        }
    }

    var color: Color {
        switch self {
        case .wifiAP, .rawFrames: Theme.Colors.wifi
        case .wifiClient: Theme.Colors.wifiClient
        case .ble: Theme.Colors.bluetooth
        }
    }

    var key: SettingKey<Bool> {
        switch self {
        case .wifiAP: Settings.surveyWifiAP
        case .wifiClient: Settings.surveyWifiClient
        case .ble: Settings.surveyBLE
        case .rawFrames: Settings.surveyRawFrames
        }
    }

    /// The name inside a sentence ("Will record Wi-Fi APs and BLE ...").
    var sentenceName: String {
        switch self {
        case .wifiAP: "Wi-Fi access points"
        case .wifiClient: "Wi-Fi clients"
        case .ble: "BLE devices"
        case .rawFrames: "raw frames"
        }
    }
}

/// Where survey data can go.
enum SurveyDestination: CaseIterable, Identifiable {
    case logFiles, mqtt, grpc, nsAnalytics

    var id: Self { self }

    var title: String {
        switch self {
        case .logFiles: "Files"
        case .mqtt: "MQTT stream"
        case .grpc: "gRPC stream"
        case .nsAnalytics: "NS Analytics"
        }
    }

    var symbol: String {
        switch self {
        case .logFiles: "doc.text"
        case .mqtt: "antenna.radiowaves.left.and.right"
        case .grpc: "server.rack"
        case .nsAnalytics: "chart.bar.xaxis"
        }
    }

    var key: SettingKey<Bool> {
        switch self {
        case .logFiles: Settings.destinationLogFiles
        case .mqtt: Settings.destinationMQTT
        case .grpc: Settings.destinationGRPC
        case .nsAnalytics: Settings.destinationNSAnalytics
        }
    }

    var route: SettingsRoute {
        switch self {
        case .logFiles: .logFiles
        case .mqtt: .mqtt
        case .grpc: .grpc
        case .nsAnalytics: .nsAnalytics
        }
    }

    /// The name inside a sentence ("... to files on this iPhone and your MQTT broker").
    var sentenceName: String {
        switch self {
        case .logFiles: "files on this iPhone"
        case .mqtt: "your MQTT broker"
        case .grpc: "your gRPC server"
        case .nsAnalytics: "NS Analytics"
        }
    }

    /// Destination kinds (snapshot keys) that make up this row.
    var kinds: [DestinationKind] {
        switch self {
        case .logFiles: [.nsCSV, .wigle, .pcap]
        case .mqtt: [.mqtt]
        case .grpc: [.grpc]
        case .nsAnalytics: [.nsAnalytics]
        }
    }
}

/// The choices on the Ready screen, read from settings.
struct SurveySetup: Equatable {
    var protocols: Set<SurveyProtocol> = []
    /// Destinations the user turned on.
    var destinationsOn: Set<SurveyDestination> = []
    /// Destinations that have what they need (a broker, a server, a workspace).
    var configured: Set<SurveyDestination> = [.logFiles]
    /// The second line of each configured destination: broker, server, workspace.
    var details: [SurveyDestination: String] = [:]
    /// Destinations that cannot take this survey, with the reason.
    var unavailable: [SurveyDestination: String] = [:]

    /// `demoBoardInUse`: made-up demo data never goes to NS Analytics.
    static func read(_ settings: SettingsStore, registered: Bool, demoBoardInUse: Bool = false) -> SurveySetup {
        var setup = SurveySetup()
        if demoBoardInUse { setup.unavailable[.nsAnalytics] = "Not available with the demo board" }
        setup.protocols = Set(SurveyProtocol.allCases.filter { settings[$0.key] })
        setup.destinationsOn = Set(SurveyDestination.allCases.filter { settings[$0.key] })
        setup.details[.logFiles] = settings[Settings.logWigleCSV] ? "CSV and WiGLE CSV on this iPhone" : "CSV on this iPhone"
        let mqttHost = settings[Settings.mqttHost].trimmingCharacters(in: .whitespaces)
        if !mqttHost.isEmpty {
            setup.configured.insert(.mqtt)
            setup.details[.mqtt] = "\(mqttHost):\(settings[Settings.mqttPort])"
        }
        let grpcHost = settings[Settings.grpcHost].trimmingCharacters(in: .whitespaces)
        if !grpcHost.isEmpty {
            setup.configured.insert(.grpc)
            setup.details[.grpc] = "\(grpcHost):\(settings[Settings.grpcPort])"
        }
        if registered {
            setup.configured.insert(.nsAnalytics)
            let name = settings[Settings.nsAnalyticsWorkspaceName]
            setup.details[.nsAnalytics] = name.isEmpty ? "Connected" : name
        }
        return setup
    }

    /// Turned on and ready.
    var activeDestinations: [SurveyDestination] {
        SurveyDestination.allCases.filter {
            destinationsOn.contains($0) && configured.contains($0) && unavailable[$0] == nil
        }
    }

    var orderedProtocols: [SurveyProtocol] {
        SurveyProtocol.allCases.filter(protocols.contains)
    }

    /// "Will save Wi-Fi access points and clients to files on this iPhone."
    var sentence: String? {
        guard !protocols.isEmpty, !activeDestinations.isEmpty else { return nil }
        var what = orderedProtocols.filter { $0 != .rawFrames || activeDestinations.contains(.logFiles) }.map(\.sentenceName)
        if protocols.isSuperset(of: [.wifiAP, .wifiClient]) {
            what.removeAll { $0 == SurveyProtocol.wifiClient.sentenceName }
            what[0] = "Wi-Fi access points and clients"
        }
        guard !what.isEmpty else { return nil }
        let verb = activeDestinations == [.logFiles] ? "save" : "record"
        return "Will \(verb) \(Self.list(what)) to \(Self.list(activeDestinations.map(\.sentenceName)))."
    }

    /// Parts of the setup that go nowhere.
    var warnings: [String] {
        var warnings: [String] = []
        if protocols.contains(.rawFrames) && !activeDestinations.contains(.logFiles) {
            warnings.append("Raw frames are only saved to files, so they won't be kept. Turn on Files to keep them.")
        }
        if protocols == [.rawFrames] && activeDestinations.contains(.logFiles) && activeDestinations.count > 1 {
            warnings.append("Streams and NS Analytics won't receive anything from raw frames alone.")
        }
        return warnings
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}

/// Why Start can't run, worst first.
enum StartBlock: Equatable {
    /// The survey database could not be opened; nothing would be kept.
    case storageUnavailable
    case bluetoothOff
    case bluetoothDenied
    case noBoard
    case boardNeedsUpdate(String)
    case nothingToSurvey
    case noDestination
    case locationDenied
    case locationServicesOff
    case locationRestricted

    var message: String {
        switch self {
        case .storageUnavailable: "Storage is not available, so a survey can't be saved"
        case .bluetoothOff: "Turn on Bluetooth to use your board"
        case .bluetoothDenied: "Allow Bluetooth for Network Survey in Settings"
        case .noBoard: "Connect a board to start"
        case .boardNeedsUpdate(let name): "\(name) needs a firmware update before it can survey"
        case .nothingToSurvey: "Choose at least one thing to survey"
        case .noDestination: "Turn on a place for the data to go"
        case .locationDenied: "Allow location access so records can be placed on the map"
        case .locationServicesOff: "Turn on Location Services so records can be placed on the map"
        case .locationRestricted: "Location is restricted on this iPhone, so records can't be placed on the map"
        }
    }

    static func evaluate(
        setup: SurveySetup, readyBoards: Int, realBoardsReady: Bool, incompatibleBoard: String?,
        bluetooth: BluetoothAccess, location: LocationAccess, storageAvailable: Bool = true
    ) -> StartBlock? {
        if !storageAvailable { return .storageUnavailable }
        if readyBoards == 0 {
            if bluetooth == .off { return .bluetoothOff }
            if bluetooth == .denied || bluetooth == .restricted { return .bluetoothDenied }
            if let incompatibleBoard { return .boardNeedsUpdate(incompatibleBoard) }
            return .noBoard
        }
        if setup.protocols.isEmpty { return .nothingToSurvey }
        if setup.activeDestinations.isEmpty { return .noDestination }
        if realBoardsReady {
            switch location {
            case .denied: return .locationDenied
            case .servicesOff: return .locationServicesOff
            case .restricted: return .locationRestricted
            case .notDetermined, .approximate, .ready: break
            }
        }
        return nil
    }
}

/// One destination row while a survey runs.
struct LiveDestinationStatus: Equatable {
    var word: String
    var level: StatusLevel
    var detail: [String]
    var offersUpload = false

    static func make(
        _ destination: SurveyDestination, snapshots: [String: DestinationSnapshot],
        upload: NSAnalyticsUploader.State?, uploadIntervalMinutes: Int = 15, now: Date = Date()
    ) -> LiveDestinationStatus {
        let parts = destination.kinds.compactMap { snapshots[$0.rawValue] }
        guard let main = parts.first else {
            return LiveDestinationStatus(word: "Starting", level: .pending, detail: [])
        }
        switch destination {
        case .logFiles:
            let files = parts.flatMap(\.files)
            let bytes = files.reduce(Int64(0)) { $0 + $1.bytes }
            if case .error(let message) = main.status {
                return LiveDestinationStatus(word: "Not saving", level: .failing, detail: [message])
            }
            let detail = files.isEmpty
                ? "Files appear with the first record"
                : "\(files.count) \(files.count == 1 ? "file" : "files") · \(bytes.formatted(.byteCount(style: .file)))"
            return LiveDestinationStatus(word: "Saving", level: .good, detail: [detail])
        case .mqtt, .grpc:
            var detail: [String] = []
            if main.queueDepth > 0 { detail.append("\(main.queueDepth.formatted()) waiting to send") }
            if main.droppedRecords > 0 { detail.append("\(main.droppedRecords.formatted()) thrown away, the queue was full") }
            switch main.status {
            case .running:
                if detail.isEmpty { detail.append("\(main.recordsAccepted.formatted()) sent") }
                return LiveDestinationStatus(word: "Live", level: main.droppedRecords > 0 ? .held : .good, detail: detail)
            case .starting, .off:
                return LiveDestinationStatus(word: "Connecting", level: .pending, detail: detail)
            case .error(let message):
                return LiveDestinationStatus(word: "Can't connect", level: .failing, detail: [message] + detail)
            }
        case .nsAnalytics:
            let pending = upload?.pending ?? main.queueDepth
            var detail: [String] = []
            if let last = upload?.lastUploadAt ?? main.lastSuccessAt {
                detail.append("Last upload \(last.formatted(date: .omitted, time: .shortened))")
            }
            if let paused = upload?.pausedUntil, paused > now {
                return LiveDestinationStatus(
                    word: "Paused", level: .held,
                    detail: ["Uploads resume \(paused.formatted(date: .abbreviated, time: .shortened))"] + detail,
                    offersUpload: true
                )
            }
            if case .error(let message) = main.status {
                return LiveDestinationStatus(word: "Not uploading", level: .failing, detail: [message] + detail)
            }
            if pending > 0 {
                return LiveDestinationStatus(
                    word: "Queued", level: .pending, detail: ["\(pending.formatted()) waiting to upload"] + detail,
                    offersUpload: true
                )
            }
            return LiveDestinationStatus(word: "Up to date", level: .good, detail: detail.isEmpty ? [Self.uploadSchedule(uploadIntervalMinutes)] : detail)
        }
    }

    static func uploadSchedule(_ minutes: Int) -> String {
        switch minutes {
        case ..<1: "Uploads when the survey stops"
        case 1: "Uploads every minute and when the survey stops"
        default: "Uploads every \(minutes) minutes and when the survey stops"
        }
    }
}
