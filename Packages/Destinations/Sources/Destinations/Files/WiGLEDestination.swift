import BoardProtocol
import Foundation
import NSMessaging

/// File logging in the WiGLE CSV format (WigleWifi-1.6): one row per AP
/// observation and, if BLE is on, per BLE observation. Rows without a location
/// are left out because WiGLE cannot place them.
public actor WiGLEDestination: Destination {
    public nonisolated let kind = DestinationKind.wigle

    /// Written as `board=` in the pre-header, for example "ESP32-C5".
    private let boardModel: String
    private var session: SessionInfo?
    private var file: CSVFile?
    private var closedFile: DestinationSnapshot.File?
    private var recordsAccepted = 0
    private var lastError: String?
    private let times = FirstSeenFormatter()

    public static let header = [
        "MAC", "SSID", "AuthMode", "FirstSeen", "Channel", "Frequency", "RSSI", "CurrentLatitude",
        "CurrentLongitude", "AltitudeMeters", "AccuracyMeters", "RCOIs", "MfgrId", "Type",
    ]

    public init(boardModel: String = "ESP32") {
        self.boardModel = boardModel
    }

    public func start(_ session: SessionInfo) async throws {
        try FileManager.default.createDirectory(at: session.directory, withIntermediateDirectories: true)
        self.session = session
        file = nil
        closedFile = nil
        recordsAccepted = 0
        lastError = nil
    }

    public func accept(_ records: [SurveyRecord]) async {
        for record in records {
            switch record.kind {
            case .ap(let ns, let ap): write(Self.row(ns.data, ap, times))
            case .ble(let ns, _): write(Self.row(ns.data, times))
            default: break
            }
        }
        do { try file?.flush() } catch { lastError = error.localizedDescription }
    }

    public func stop() async {
        if let file {
            do { try file.close() } catch { lastError = error.localizedDescription }
            closedFile = .init(url: file.url, bytes: file.bytesWritten)
        }
        file = nil
        session = nil
    }

    public func snapshot() async -> DestinationSnapshot {
        var snapshot = DestinationSnapshot(status: lastError.map { .error($0) } ?? (session == nil ? .off : .running))
        snapshot.recordsAccepted = recordsAccepted
        snapshot.lastError = lastError
        if let file { snapshot.files = [.init(url: file.url, bytes: file.bytesWritten)] }
        if let closedFile { snapshot.files = [closedFile] }
        return snapshot
    }

    private func write(_ row: [String]?) {
        guard let row, let file = openFile() else { return }
        file.row(row)
        recordsAccepted += 1
    }

    private func openFile() -> CSVFile? {
        if let file { return file }
        guard let session else { return nil }
        let url = FileNaming.uniqueURL(in: session.directory, prefix: "craxiom-wigle-", session: session, extension: "csv")
        do {
            let file = try CSVFile(url: url, dialect: .rfc4180)
            file.row(Self.preHeader(session: session, boardModel: boardModel))
            file.row(Self.header)
            self.file = file
            return file
        } catch {
            lastError = "Could not create \(url.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }

    static func preHeader(session: SessionInfo, boardModel: String) -> [String] {
        [
            "WigleWifi-1.6", "appRelease=\(session.appVersion)", "model=\(session.deviceModel)",
            "release=\(session.osVersion)", "device=NetworkSurvey-iOS", "display=", "board=\(boardModel)",
            "brand=Apple", "star=Sol", "body=3", "subBody=0",
        ]
    }

    static func row(_ data: WifiBeaconRecordData, _ ap: NSBApObservation, _ times: FirstSeenFormatter) -> [String]? {
        guard let location = location(data) else { return nil }
        return [
            data.bssid, data.ssid, WiGLEAuthMode.string(ap), times.string(data.deviceTime),
            data.channel.map { String($0) } ?? "", data.frequencyMhz.map { String($0) } ?? "",
            data.signalStrength.map { String(Int($0)) } ?? "",
        ] + location + ["", "", "WIFI"]
    }

    static func row(_ data: BluetoothRecordData, _ times: FirstSeenFormatter) -> [String]? {
        guard let location = location(data) else { return nil }
        let manufacturer = UInt32(data.companyId, radix: 16).map { String($0) } ?? ""
        return [
            data.sourceAddress, data.otaDeviceName, "Misc [LE]", times.string(data.deviceTime), "0", "",
            data.signalStrength.map { String(Int($0)) } ?? "",
        ] + location + ["", manufacturer, "BLE"]
    }

    private static func location(_ data: some NSCommonData) -> [String]? {
        guard data.latitude != 0 || data.longitude != 0 else { return nil }
        return [
            JavaNumberFormat.fixed(data.latitude, decimals: 6), JavaNumberFormat.fixed(data.longitude, decimals: 6),
            JavaNumberFormat.string(data.altitude),
            String(data.accuracy),
        ]
    }
}

/// NS `deviceTime` (RFC 3339 with offset) as WiGLE's UTC `yyyy-MM-dd HH:mm:ss`.
final class FirstSeenFormatter {
    private let withFraction = ISO8601DateFormatter()
    private let withoutFraction = ISO8601DateFormatter()
    private let output = DateFormatter()

    init() {
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        withoutFraction.formatOptions = [.withInternetDateTime]
        output.locale = Locale(identifier: "en_US_POSIX")
        output.timeZone = TimeZone(identifier: "UTC")
        output.dateFormat = "yyyy-MM-dd HH:mm:ss"
    }

    func string(_ deviceTime: String) -> String {
        guard let date = withFraction.date(from: deviceTime) ?? withoutFraction.date(from: deviceTime) else { return "" }
        return output.string(from: date)
    }
}

/// WiGLE's AuthMode column: Android `ScanResult.capabilities` style, for
/// example `[WPA2-PSK-CCMP][RSN-PSK+SAE-CCMP][ESS]`. The board does not report
/// the RSN capabilities, so `[MFPR]` and `[MFPC]` are never written.
enum WiGLEAuthMode {
    static func string(_ ap: NSBApObservation) -> String {
        let privacy = ap.capabilityInfo & 0x0010 != 0
        let rsnAKMs = ap.akmSuites.filter { $0 >> 8 == 0x000FAC }
        let wpaAKMs = ap.akmSuites.filter { $0 >> 8 == 0x0050F2 }
        let rsnCiphers = ap.pairwiseCiphers.filter { $0 >> 8 == 0x000FAC }
        let wpaCiphers = ap.pairwiseCiphers.filter { $0 >> 8 == 0x0050F2 }
        let hasRSN = !rsnAKMs.isEmpty || !rsnCiphers.isEmpty || ap.groupCipher >> 8 == 0x000FAC
        let hasWPA = !wpaAKMs.isEmpty || !wpaCiphers.isEmpty || ap.groupCipher >> 8 == 0x0050F2
        var text = ""
        if privacy && !hasRSN && !hasWPA { text += "[WEP]" }
        if hasWPA { text += tag("WPA", wpaAKMs.map(akm), wpaCiphers) }
        if hasRSN {
            let names = rsnAKMs.map(akm)
            // Android adds a legacy WPA2 tag for the PSK and EAP key management.
            let legacy = names.filter { $0 == "PSK" || $0 == "EAP/SHA1" }
            if !legacy.isEmpty { text += tag("WPA2", legacy, rsnCiphers) }
            text += tag("RSN", names, rsnCiphers)
        }
        if ap.capabilityInfo & 0x0001 != 0 { text += "[ESS]" }
        if ap.capabilityInfo & 0x0002 != 0 { text += "[IBSS]" }
        if ap.wps { text += "[WPS]" }
        return text
    }

    private static func tag(_ proto: String, _ akms: [String], _ ciphers: [UInt32]) -> String {
        var text = "[" + proto
        if !akms.isEmpty { text += "-" + akms.joined(separator: "+") }
        let names = ciphers.compactMap(cipher)
        if !names.isEmpty { text += "-" + names.joined(separator: "+") }
        return text + "]"
    }

    static func akm(_ selector: UInt32) -> String {
        let type = selector & 0xFF
        if selector >> 8 == 0x0050F2 {
            return [1: "EAP/SHA1", 2: "PSK"][type] ?? "?"
        }
        let names: [UInt32: String] = [
            1: "EAP/SHA1", 2: "PSK", 3: "FT/EAP", 4: "FT/PSK", 5: "EAP/SHA256", 6: "PSK-SHA256", 8: "SAE",
            9: "FT/SAE", 11: "EAP_SUITE_B", 12: "EAP_SUITE_B_192", 18: "OWE", 24: "SAE_EXT_KEY", 25: "FT/SAE_EXT_KEY",
        ]
        return names[type] ?? "?"
    }

    static func cipher(_ selector: UInt32) -> String? {
        switch selector & 0xFF {
        case 0: nil
        case 1, 5: "WEP"
        case 2: "TKIP"
        case 4: "CCMP"
        case 8: "GCMP-128"
        case 9: "GCMP-256"
        case 10: "CCMP-256"
        default: "?"
        }
    }
}
