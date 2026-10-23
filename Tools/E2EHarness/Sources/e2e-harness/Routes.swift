import Foundation
import NIOHTTP1
import Synchronization

/// The NS Analytics device API as far as the app uses it, plus the harness's
/// own control endpoints under `/e2e/`.
struct Routes: Sendable {
    static let deviceToken = "e2e-device-token"
    static let workspaceName = "E2E workspace"
    /// Types NS Analytics stores today; any other type is answered as skipped.
    static let storedTypes: Set<String> = ["wifi", "bluetooth", "device_status"]

    let tally: Tally
    let ports: [String: Int]

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case (.GET, "/e2e/config"):
            return .json(ports)
        case (.GET, "/e2e/counts"):
            return .encoded(tally.snapshot)
        case (.POST, "/e2e/reset"):
            tally.reset()
            return .json(["ok": true])
        case (.POST, "/e2e/pcap"):
            let path = (try? JSONSerialization.jsonObject(with: request.body) as? [String: String])?["path"] ?? ""
            return .json(PcapCheck.run(path: path))
        case (.POST, "/api/v1/device/register"):
            return register(request)
        case (.POST, "/api/v1/device/upload"):
            return upload(request)
        case (.GET, "/api/v1/device/status"):
            return .json(["is_active": true])
        default:
            return .json(["error": "Not found"], status: .notFound)
        }
    }

    private func register(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: String],
              body["token"] == "e2e-registration-token", let deviceID = body["device_id"] else {
            return .json(["error": "Invalid or expired token"], status: .badRequest)
        }
        tally.update { $0.registrations += 1 }
        return .json([
            "device_token": Self.deviceToken, "device_id": deviceID, "workspace_id": "e2e-workspace",
            "workspace_name": Self.workspaceName,
        ])
    }

    /// Answers like the ingestion service: "completed" with processed and
    /// skipped counts; a batch ID seen before is reported as already processed.
    private func upload(_ request: HTTPRequest) -> HTTPResponse {
        guard request.headers.first(name: "Authorization") == "Bearer \(Self.deviceToken)" else {
            return .json(["error": "Invalid token", "error_code": "INVALID_TOKEN"], status: .unauthorized)
        }
        guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let batchID = body["batch_id"] as? String, let groups = body["records"] as? [[String: Any]] else {
            return .json(["error": "Invalid request body"], status: .badRequest)
        }
        var processed = 0, skipped = 0, total = 0
        let duplicate = tally.snapshot.nsAnalyticsBatchIDs.contains(batchID)
        if !duplicate {
            tally.update { tally in
                tally.nsAnalyticsBatches += 1
                tally.nsAnalyticsBatchIDs.insert(batchID)
                for group in groups {
                    let type = group["type"] as? String ?? ""
                    let messages = group["messages"] as? [Any] ?? []
                    total += messages.count
                    for message in messages {
                        tally.nsAnalytics[type, default: ChannelTally()].add(RecordFields(json: message) ?? RecordFields())
                    }
                    if Self.storedTypes.contains(type) {
                        processed += messages.count
                    } else {
                        skipped += messages.count
                        tally.nsAnalyticsSkipped[type, default: 0] += messages.count
                    }
                }
            }
        }
        return .json([
            "message": duplicate ? "Batch already processed" : "Upload processed", "batch_id": batchID,
            "status": "completed", "total_records": total, "processed": processed, "skipped": skipped, "failed": 0,
            "workspace_name": Self.workspaceName,
        ])
    }
}

/// Validates a pcapng file with Wireshark's command line tools.
enum PcapCheck {
    static func run(path: String) -> [String: Any] {
        guard FileManager.default.fileExists(atPath: path) else { return ["error": "No file at \(path)"] }
        guard let tshark = Tools.find("tshark"), let capinfos = Tools.find("capinfos") else {
            return ["error": "tshark and capinfos are needed (Wireshark)"]
        }
        let info = Tools.run(capinfos, ["-M", path])
        let frames = Tools.run(tshark, ["-r", path, "-T", "fields", "-e", "frame.interface_name", "-e", "wlan.bssid"])
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        let bad = Tools.run(tshark, ["-r", path, "-Y", "_ws.malformed || _ws.expert.severity >= error"])
            .split(separator: "\n", omittingEmptySubsequences: true)
        return [
            "packets": frames.count,
            "interfaces": Array(Set(frames.map { $0[0] })).sorted(),
            "bssids": Array(Set(frames.compactMap { $0.count > 1 ? $0[1] : nil })).sorted(),
            "badPackets": bad.count,
            "capinfos": info,
        ]
    }
}

enum Tools {
    static func find(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let directories = path.split(separator: ":").map(String.init) + ["/Applications/Wireshark.app/Contents/MacOS"]
        return directories.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return "\(error)" }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self)
    }
}

/// Holds the routes once every port is known (the HTTP server starts first).
final class RoutesBox: Sendable {
    private let routes = Mutex<Routes?>(nil)

    var value: Routes? { routes.withLock { $0 } }

    func set(_ value: Routes) {
        routes.withLock { $0 = value }
    }
}
