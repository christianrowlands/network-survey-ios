import BoardKit
import BoardProtocol
import Destinations
import Foundation
import Synchronization
@testable import SurveyCore

/// Synthetic addresses only: locally administered or the documentation block.
enum Fixtures {
    static let base = Date(timeIntervalSince1970: 1_800_000_000)
    static let installID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let app = AppInfo(deviceModel: "iPhone17,3", osVersion: "18.0", appVersion: "0.1.0")

    static func mac(_ text: String) -> Data {
        Data(text.split(separator: ":").map { UInt8($0, radix: 16)! })
    }

    static func ms(_ date: Date) -> UInt64 {
        UInt64(date.timeIntervalSince1970 * 1000)
    }

    static func ap(
        _ bssid: String, ssid: String = "ExampleNet", rssi: Int32 = -60, channel: UInt32 = 6,
        band: NSBBand = .ghz24, security: NSBSecurityType = .wpa2, time: Date = base
    ) -> NSBRecord.OneOf_Kind {
        var ap = NSBApObservation()
        ap.bssid = mac(bssid)
        ap.ssid = Data(ssid.utf8)
        ap.ssidHidden = ssid.isEmpty
        ap.rssiLast = rssi
        ap.rssiMax = rssi
        ap.channel = channel
        ap.frequencyMhz = band == .ghz5 ? 5000 + channel * 5 : 2407 + channel * 5
        ap.band = band
        ap.security = security
        ap.beaconCount = 3
        ap.boardTimeMs = ms(time)
        return .ap(ap)
    }

    static func client(
        _ mac: String, associated: String? = nil, rssi: Int32 = -70, time: Date = base
    ) -> NSBRecord.OneOf_Kind {
        var client = NSBClientObservation()
        client.clientMac = Fixtures.mac(mac)
        client.associatedBssid = associated.map(Fixtures.mac) ?? Data()
        client.rssiLast = rssi
        client.rssiMax = rssi
        client.channel = 6
        client.band = .ghz24
        client.frameCount = 2
        client.sourceFlags = 1
        client.locallyAdministered = MACAddress.isLocallyAdministered(client.clientMac)
        client.boardTimeMs = ms(time)
        return .client(client)
    }

    static func probe(_ mac: String, ssid: String = "", rssi: Int32 = -75, time: Date = base) -> NSBRecord.OneOf_Kind {
        var probe = NSBProbeObservation()
        probe.clientMac = Fixtures.mac(mac)
        probe.ssid = Data(ssid.utf8)
        probe.rssiLast = rssi
        probe.rssiMax = rssi
        probe.channel = 1
        probe.band = .ghz24
        probe.count = 1
        probe.locallyAdministered = MACAddress.isLocallyAdministered(probe.clientMac)
        probe.boardTimeMs = ms(time)
        return .probe(probe)
    }

    static func ble(_ address: String, name: String = "", rssi: Int32 = -80, time: Date = base) -> NSBRecord.OneOf_Kind {
        var ble = NSBBleObservation()
        ble.address = mac(address)
        ble.addressType = .random
        ble.localName = Data(name.utf8)
        ble.rssiLast = rssi
        ble.rssiMax = rssi
        ble.count = 4
        ble.companyID = 0x004C
        ble.boardTimeMs = ms(time)
        return .ble(ble)
    }

    static func gps(latitude: Double, longitude: Double, hdop: Float = 1, time: Date = base) -> NSBRecord.OneOf_Kind {
        var fix = NSBGpsFix()
        fix.latitude = latitude
        fix.longitude = longitude
        fix.hdop = hdop
        fix.fixQuality = 1
        fix.satellites = 8
        fix.fixTimeMs = ms(time)
        fix.boardTimeMs = ms(time)
        return .gps(fix)
    }

    static func batch(_ kinds: [NSBRecord.OneOf_Kind], receivedAt: Date = base, missed: Int = 0) -> ReceivedRecordBatch {
        var batch = NSBRecordBatch()
        batch.timeSynced = true
        batch.records = kinds.map { kind in
            var record = NSBRecord()
            record.kind = kind
            return record
        }
        return ReceivedRecordBatch(sequence: 0, missedNotifications: missed, batch: batch, receivedAt: receivedAt)
    }

    static func phoneFix(latitude: Double = 38.89, longitude: Double = -77.03, accuracy: Double = 5, time: Date = base) -> LocationSample {
        LocationSample(latitude: latitude, longitude: longitude, horizontalAccuracy: accuracy, timestamp: time, source: .phone)
    }

    static func context(plan: SurveyPlan = SurveyPlan(ble: true, rawFrames: true), sessionID: String = "S1") -> SessionContext {
        SessionContext(
            sessionID: sessionID, missionId: MissionID.make(installID: installID, startedAt: base),
            startedAt: base, deviceSerialNumber: installID.uuidString, deviceName: "TestPhone", plan: plan,
            app: app, directory: SessionFiles.directory(root: FileManager.default.temporaryDirectory, startedAt: base)
        )
    }

    static func sessionRow(id: String = "S1") -> SessionRow {
        SessionRow(
            id: id, missionId: MissionID.make(installID: installID, startedAt: base), startedAt: base, stoppedAt: nil,
            deviceSerialNumber: installID.uuidString, deviceName: "TestPhone", wifiAP: true, wifiClient: true,
            ble: true, rawFrames: false, recordCount: 0, filteredCount: 0
        )
    }
}

/// A destination that keeps everything it is given.
final class RecordingSink: SurveyRecordSink {
    struct State {
        var started: [SessionContext] = []
        var outputs: [SurveyOutput] = []
        var raw: [RawFrameOutput] = []
        var stopped = 0
    }

    let name = "recording"
    let state = Mutex(State())
    let startDelay: Duration
    /// Never returns from accept or stop, like a destination blocked on I/O.
    let stuck: Bool

    init(startDelay: Duration = .zero, stuck: Bool = false) {
        self.startDelay = startDelay
        self.stuck = stuck
    }

    func start(_ session: SessionContext) async throws {
        if startDelay > .zero { try? await Task.sleep(for: startDelay) }
        state.withLock { $0.started.append(session) }
    }

    func accept(_ records: [SurveyOutput]) async {
        if stuck { await hang() }
        state.withLock { $0.outputs += records }
    }

    private func hang() async {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
    }

    func acceptRaw(_ frames: [RawFrameOutput]) async {
        state.withLock { $0.raw += frames }
    }

    func stop() async {
        if stuck { await hang() }
        state.withLock { $0.stopped += 1 }
    }

    func snapshots() async -> [String: DestinationSnapshot] {
        [name: DestinationSnapshot(status: state.withLock { $0.stopped > 0 ? .off : .running })]
    }

    var outputs: [SurveyOutput] { state.withLock { $0.outputs } }

    func numbers(_ type: MessageType) -> [Int] {
        outputs.filter { $0.type == type }.map(\.context.recordNumber)
    }
}

struct FixedBattery: BatteryProvider {
    var level: Double?
    func batteryLevel() async -> Double? { level }
}

/// Polls until `condition` holds or the timeout passes.
func waitUntil(
    isolation: isolated (any Actor)? = #isolation, timeout: Duration = .seconds(10), _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
