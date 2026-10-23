import Foundation
import SurveyCore

/// The local servers `scripts/e2e.sh` starts (Tools/E2EHarness): a mosquitto
/// broker with a counting subscriber, an NS Messaging gRPC server and an NS
/// Analytics stub. The script passes their control address as NS_E2E_HARNESS.
struct HarnessClient: Sendable {
    struct Ports: Decodable {
        var httpPort: Int
        var mqttPort: Int
        var grpcPort: Int
    }

    /// What arrived on one MQTT topic, gRPC method or NS Analytics record type.
    struct Channel: Decodable {
        var count = 0
        var missionIds: Set<String> = []
        var serials: Set<String> = []
        var deviceNames: Set<String> = []
        var recordNumbers: [Int] = []
        var locations: [[Double]] = []
        var addresses: Set<String> = []
    }

    struct Counts: Decodable {
        var mqtt: [String: Channel]
        var grpc: [String: Channel]
        var nsAnalytics: [String: Channel]
        var nsAnalyticsSkipped: [String: Int]
        var nsAnalyticsBatches: Int
        var registrations: Int
        var handshakes: Int
        var mqttUnparsed: Int
    }

    struct PcapReport: Decodable {
        var packets: Int?
        var interfaces: [String]?
        var bssids: [String]?
        var badPackets: Int?
        var capinfos: String?
        var error: String?
    }

    let base: URL

    static var fromEnvironment: HarnessClient? {
        guard let address = ProcessInfo.processInfo.environment["NS_E2E_HARNESS"], !address.isEmpty,
              let url = URL(string: "http://\(address)") else { return nil }
        return HarnessClient(base: url)
    }

    func ports() async throws -> Ports { try await get("e2e/config") }
    func counts() async throws -> Counts { try await get("e2e/counts") }

    func reset() async throws {
        _ = try await post("e2e/reset", body: [:])
    }

    /// capinfos and tshark run on the Mac, where the simulator's files live.
    func checkPcap(_ url: URL) async throws -> PcapReport {
        try JSONDecoder().decode(PcapReport.self, from: try await post("e2e/pcap", body: ["path": url.path]))
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent(path))
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post(_ path: String, body: [String: String]) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await URLSession.shared.data(for: request).0
    }
}

/// A CSV file read back: `#` comment lines skipped, then a header and rows by
/// column name.
struct CSVTable {
    var header: [String] = []
    var rows: [[String: String]] = []

    init(url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var records = Self.parse(text)
        // The first column (deviceTime) never starts with "#", so such lines are comments.
        records.removeAll { $0.first?.hasPrefix("#") == true }
        guard let header = records.first else { return }
        self.header = header
        rows = records.dropFirst().map { Dictionary(uniqueKeysWithValues: zip(header, $0)) }
    }

    func column(_ name: String) -> [String] { rows.map { $0[name] ?? "" } }

    /// RFC 4180: quoted fields may hold commas, quotes ("") and line breaks.
    static func parse(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var quoted = false
        var iterator = Array(text.unicodeScalars).makeIterator()
        var pending: Unicode.Scalar?
        func next() -> Unicode.Scalar? {
            if let scalar = pending { pending = nil; return scalar }
            return iterator.next()
        }
        while let scalar = next() {
            if quoted {
                if scalar == "\"" {
                    if let following = next() {
                        if following == "\"" { field.unicodeScalars.append("\"") } else { quoted = false; pending = following }
                    } else {
                        quoted = false
                    }
                } else {
                    field.unicodeScalars.append(scalar)
                }
                continue
            }
            switch scalar {
            case "\"": quoted = true
            case ",":
                record.append(field)
                field = ""
            case "\r": break
            case "\n":
                record.append(field)
                records.append(record)
                record = []
                field = ""
            default: field.unicodeScalars.append(scalar)
            }
        }
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }
        return records
    }
}

extension Array where Element == Int {
    /// True when the numbers are exactly 1...count in some order.
    var isOneToCount: Bool { isEmpty || sorted() == Array(1...count) }
}

/// Polls until `condition` holds or `timeout` passes.
@MainActor
func eventually(timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(200))
    }
    return await condition()
}

extension GeoPoint {
    init(row: [String: String]) {
        self.init(latitude: Double(row["latitude"] ?? "") ?? 0, longitude: Double(row["longitude"] ?? "") ?? 0)
    }

    var isZero: Bool { latitude == 0 && longitude == 0 }
}
