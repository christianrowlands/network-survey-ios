import Foundation
import NSMessaging

public struct NSAnalyticsConfig: Sendable, Equatable {
    /// How often to upload while a survey runs; nil uploads only at stop.
    public var uploadInterval: Duration?
    public var uploadWifi: Bool
    public var uploadBluetooth: Bool
    public var uploadDeviceStatus: Bool
    /// Experimental: NS Analytics does not store probe requests today and
    /// answers them as skipped, which counts as done.
    public var uploadProbeRequests: Bool
    /// Experimental: station records, also skipped by NS Analytics today.
    public var uploadStationRecords: Bool
    /// Start an upload when the survey stops (it may finish in the background).
    public var uploadOnStop: Bool
    /// Leave out records without a location. NS Analytics stores a missing
    /// position as latitude 0, longitude 0 (the Android app never sends such
    /// records). Files, MQTT and gRPC still get them.
    public var requireLocation: Bool

    public init(
        uploadInterval: Duration? = .seconds(15 * 60), uploadWifi: Bool = true, uploadBluetooth: Bool = true,
        uploadDeviceStatus: Bool = true, uploadProbeRequests: Bool = false, uploadStationRecords: Bool = false,
        uploadOnStop: Bool = true, requireLocation: Bool = true
    ) {
        self.uploadInterval = uploadInterval
        self.uploadWifi = uploadWifi
        self.uploadBluetooth = uploadBluetooth
        self.uploadDeviceStatus = uploadDeviceStatus
        self.uploadProbeRequests = uploadProbeRequests
        self.uploadStationRecords = uploadStationRecords
        self.uploadOnStop = uploadOnStop
        self.requireLocation = requireLocation
    }
}

/// NS Analytics record type names in the upload request.
public enum NSAnalyticsRecordType {
    public static let wifi = "wifi"
    public static let bluetooth = "bluetooth"
    public static let deviceStatus = "device_status"
    /// Experimental, not accepted by NS Analytics today.
    public static let wifiProbeRequest = "wifi_probe_request"
    /// Experimental, not accepted by NS Analytics today.
    public static let wifiStation = "wifi_station"
}

/// Queues records for NS Analytics during a survey and uploads them through
/// the shared `NSAnalyticsUploader`, which keeps working after the survey
/// stops. Nothing is queued while the phone is not registered (like the
/// Android app, which collects only for a connected workspace), so the queue
/// cannot grow without bound; records already queued stay for a later
/// registration.
public actor NSAnalyticsDestination: Destination {
    public nonisolated let kind = DestinationKind.nsAnalytics

    public nonisolated let uploader: NSAnalyticsUploader
    private let config: NSAnalyticsConfig
    private var running = false
    private var periodic: Task<Void, Never>?
    private var recordsAccepted = 0
    private var lastError: String?
    private var lastOutcome: NSAnalyticsUploader.Outcome?
    private var skippedUnregistered = 0

    public init(uploader: NSAnalyticsUploader, config: NSAnalyticsConfig = NSAnalyticsConfig()) {
        self.uploader = uploader
        self.config = config
    }

    public func start(_ session: SessionInfo) async throws {
        running = true
        recordsAccepted = 0
        skippedUnregistered = 0
        lastError = nil
        if let interval = config.uploadInterval {
            periodic = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    if Task.isCancelled { return }
                    await self?.upload()
                }
            }
        }
    }

    public func accept(_ records: [SurveyRecord]) async {
        guard running else { return }
        guard uploader.isRegistered else {
            skippedUnregistered += records.count
            return
        }
        let rows: [(type: String, json: String)] = records.compactMap { record -> (type: String, json: String)? in
            if config.requireLocation && !Self.hasLocation(record) { return nil }
            return switch record.kind {
            case .ap(let ns, _): config.uploadWifi ? (NSAnalyticsRecordType.wifi, ns.jsonString()) : nil
            case .ble(let ns, _): config.uploadBluetooth ? (NSAnalyticsRecordType.bluetooth, ns.jsonString()) : nil
            case .deviceStatus(let ns):
                config.uploadDeviceStatus ? (NSAnalyticsRecordType.deviceStatus, ns.jsonString()) : nil
            case .probe(let ns, _):
                config.uploadProbeRequests ? (NSAnalyticsRecordType.wifiProbeRequest, ns.jsonString()) : nil
            case .client(let ns, _):
                config.uploadStationRecords ? (NSAnalyticsRecordType.wifiStation, ns.jsonString()) : nil
            case .rawFrame: nil
            }
        }
        do {
            try uploader.queue.enqueue(rows)
            recordsAccepted += rows.count
        } catch {
            lastError = "Could not queue records for NS Analytics: \(error.localizedDescription)"
        }
    }

    static func hasLocation(_ record: SurveyRecord) -> Bool {
        func located(_ data: some NSCommonData) -> Bool { data.latitude != 0 || data.longitude != 0 }
        switch record.kind {
        case .ap(let ns, _): return located(ns.data)
        case .ble(let ns, _): return located(ns.data)
        case .probe(let ns, _): return located(ns.data)
        case .client(let ns, _): return located(ns.data)
        case .deviceStatus(let ns): return located(ns.data)
        case .rawFrame: return false
        }
    }

    public func stop() async {
        periodic?.cancel()
        periodic = nil
        running = false
        if config.uploadOnStop {
            let uploader = uploader
            Task { _ = await uploader.uploadPending() }
        }
    }

    /// Uploads now (the "Upload now" button calls this with `ignoringPause`).
    @discardableResult
    public func upload(ignoringPause: Bool = false) async -> NSAnalyticsUploader.Outcome {
        let outcome = await uploader.uploadPending(ignoringPause: ignoringPause)
        lastOutcome = outcome
        return outcome
    }

    static let notRegistered = "This phone is not connected to an NS Analytics workspace"

    public func snapshot() async -> DestinationSnapshot {
        let state = await uploader.state()
        var status: DestinationStatus = running ? .running : .off
        if let lastError { status = .error(lastError) }
        switch lastOutcome {
        case .notRegistered: status = .error(Self.notRegistered)
        case .registrationInvalid, .deregistered, .invalidToken:
            status = .error("This phone was disconnected from its NS Analytics workspace")
        case .viewerCannotUpload: status = .error("Your workspace role does not allow uploading data")
        case .quotaExceeded(let info): status = .error(info.message.isEmpty ? "The workspace quota is used up" : info.message)
        default: break
        }
        if running && skippedUnregistered > 0 && !uploader.isRegistered { status = .error(Self.notRegistered) }
        var snapshot = DestinationSnapshot(status: status)
        snapshot.recordsAccepted = recordsAccepted
        snapshot.queueDepth = state.pending
        snapshot.lastError = lastError ?? state.lastError
        snapshot.lastSuccessAt = state.lastUploadAt
        return snapshot
    }
}
