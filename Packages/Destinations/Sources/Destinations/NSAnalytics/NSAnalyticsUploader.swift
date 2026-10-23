import Foundation
import NSMessaging

/// Uploads the NS Analytics queue with the Network Survey Android app's rules:
/// batches of up to 1000 records grouped by type, oldest first; a definitive
/// rejection counts one retry against each record and records past 3 retries
/// are dropped, so one bad record cannot block the queue; transient failures
/// never count; 402 pauses uploads until the server's Retry-After; 410 and an
/// invalid token drop the registration. Records the server skips (types it does
/// not know) arrive in a successful batch and are done.
public actor NSAnalyticsUploader {
    public static let maxBatchSize = 1000
    public static let maxRetryCount = 3
    static let defaultQuotaRetryAfter: TimeInterval = 86_400
    static let maxQuotaRetryAfter: TimeInterval = 7 * 86_400
    /// A batch with no answer after this long is released for another try.
    static let staleBatchAge: TimeInterval = 3600

    public struct QuotaInfo: Sendable, Equatable {
        public var currentUsage: Int
        public var maxRecords: Int
        public var limitType: String
        public var message: String
        public var webURL: String?
        public var pausedUntil: Date
    }

    public enum Outcome: Sendable, Equatable {
        /// Every queued record was uploaded (0 if there was nothing to do).
        case uploaded(records: Int)
        case notRegistered
        case paused(until: Date)
        case quotaExceeded(QuotaInfo)
        /// 410: the registration is no longer valid and was removed.
        case registrationInvalid
        /// The workspace removed this phone; the registration was removed.
        case deregistered
        case viewerCannotUpload
        /// 401 INVALID_TOKEN: the registration was removed.
        case invalidToken
        /// The run stopped early; the rest stays queued for the next run.
        case failed(uploaded: Int, reason: String)
        case alreadyRunning
    }

    public struct State: Sendable, Equatable {
        public var pending: Int
        public var totalUploaded: Int
        public var lastUploadAt: Date?
        public var pausedUntil: Date?
        public var lastError: String?
    }

    private enum Step {
        case next(Int)
        case stop(Outcome)
    }

    public nonisolated let queue: NSAnalyticsQueue
    private nonisolated let credentials: any NSAnalyticsCredentialStore
    private let client: NSAnalyticsClient
    private let now: @Sendable () -> Date
    private let makeBatchID: @Sendable () -> String
    private var running = false

    public init(
        queue: NSAnalyticsQueue, credentials: any NSAnalyticsCredentialStore, transport: any NSAnalyticsTransport,
        now: @escaping @Sendable () -> Date = Date.init,
        makeBatchID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.queue = queue
        self.credentials = credentials
        client = NSAnalyticsClient(transport: transport)
        self.now = now
        self.makeBatchID = makeBatchID
    }

    /// Whether a workspace registration is stored.
    public nonisolated var isRegistered: Bool { credentials.load() != nil }

    public func state() -> State {
        State(
            pending: (try? queue.pendingCount()) ?? 0,
            totalUploaded: Int((try? queue.meta("totalUploaded")) ?? nil ?? "0") ?? 0,
            lastUploadAt: date(meta: "lastUploadAt"),
            pausedUntil: date(meta: "pausedUntil"),
            lastError: (try? queue.meta("lastError")) ?? nil
        )
    }

    /// Lifts a quota pause, for "Upload now" after the user raised the quota.
    public func resume() {
        try? queue.setMeta("pausedUntil", nil)
    }

    /// Uploads everything queued, batch by batch, until the queue is empty or
    /// something stops the run.
    public func uploadPending(ignoringPause: Bool = false) async -> Outcome {
        guard !running else { return .alreadyRunning }
        running = true
        defer { running = false }
        let outcome = await run(ignoringPause: ignoringPause)
        switch outcome {
        case .failed(_, let reason): try? queue.setMeta("lastError", reason)
        case .uploaded: try? queue.setMeta("lastError", nil)
        default: break
        }
        return outcome
    }

    private func run(ignoringPause: Bool) async -> Outcome {
        guard let registration = credentials.load() else { return .notRegistered }
        if !ignoringPause, let until = date(meta: "pausedUntil"), until > now() { return .paused(until: until) }
        do {
            try queue.releaseStaleBatches(olderThan: now().addingTimeInterval(-Self.staleBatchAge))
            _ = try queue.purge(overRetryCount: Self.maxRetryCount)
        } catch {
            return .failed(uploaded: 0, reason: "Upload queue error: \(error.localizedDescription)")
        }
        var uploaded = 0
        while true {
            let entries: [NSAnalyticsQueue.Entry]
            do {
                entries = try queue.uploadable(limit: Self.maxBatchSize, maxRetryCount: Self.maxRetryCount)
            } catch {
                return .failed(uploaded: uploaded, reason: "Upload queue error: \(error.localizedDescription)")
            }
            if entries.isEmpty {
                // Nothing left (or nothing at all): a quota pause no longer applies.
                try? queue.setMeta("pausedUntil", nil)
                return .uploaded(records: uploaded)
            }
            let batchID = makeBatchID()
            let request = NSAnalyticsClient.request(registration.apiURL, "api/v1/device/upload", token: registration.deviceToken)
            let result: Result<(Data, HTTPURLResponse), Error>
            do {
                try queue.beginBatch(batchID, ids: entries.map(\.id), at: now())
                result = .success(try await client.transport.send(
                    request, body: Self.body(token: registration.deviceToken, batchID: batchID, entries: entries),
                    taskID: batchID
                ))
            } catch {
                result = .failure(error)
            }
            switch await resolve(batchID: batchID, result: result, registration: registration) {
            case .next(let count): uploaded += count
            case .stop(let outcome):
                if case .failed(_, let reason) = outcome { return .failed(uploaded: uploaded, reason: reason) }
                return outcome
            }
        }
    }

    /// Settles an upload whose answer arrived after the app was relaunched
    /// (from `BackgroundUploadTransport`). Returns what it meant, for the UI
    /// (for example a quota pause or a dropped registration); nil if the
    /// answer belongs to no known batch.
    @discardableResult
    public func completeBackgroundUpload(
        taskID: String, result: Result<(Data, HTTPURLResponse), Error>
    ) async -> Outcome? {
        guard (try? queue.batchExists(taskID)) == true, let registration = credentials.load() else { return nil }
        switch await resolve(batchID: taskID, result: result, registration: registration) {
        case .next(let count): return .uploaded(records: count)
        case .stop(let outcome): return outcome
        }
    }

    private func resolve(
        batchID: String, result: Result<(Data, HTTPURLResponse), Error>, registration: NSAnalyticsRegistration
    ) async -> Step {
        guard case .success(let (data, response)) = result else {
            try? queue.failBatch(batchID, countRetry: false)
            if case .failure(let error) = result { return .stop(.failed(uploaded: 0, reason: error.localizedDescription)) }
            return .stop(.failed(uploaded: 0, reason: "No response"))
        }
        let status = response.statusCode
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let errorCode = json?["error_code"] as? String
        if (200..<300).contains(status), json?["status"] as? String == "completed", (json?["failed"] as? Int ?? 0) == 0 {
            let count = (try? queue.completeBatch(batchID)) ?? 0
            recordSuccess(count: count)
            if let name = json?["workspace_name"] as? String, name != registration.workspaceName {
                var updated = registration
                updated.workspaceName = name
                credentials.save(updated)
            }
            return .next(count)
        }

        try? queue.failBatch(batchID, countRetry: Self.isDefinitiveRejection(status))
        switch (status, errorCode) {
        case (402, "QUOTA_EXCEEDED"):
            let retryAfter = Self.retryAfterSeconds(response.value(forHTTPHeaderField: "Retry-After"))
            let until = now().addingTimeInterval(retryAfter)
            try? queue.setMeta("pausedUntil", String(until.timeIntervalSince1970))
            return .stop(.quotaExceeded(QuotaInfo(
                currentUsage: json?["current_usage"] as? Int ?? 0, maxRecords: json?["max_records"] as? Int ?? 0,
                limitType: json?["limit_type"] as? String ?? "", message: json?["message"] as? String ?? "",
                webURL: json?["web_url"] as? String, pausedUntil: until
            )))
        case (410, "REGISTRATION_INVALID"):
            credentials.clear()
            return .stop(.registrationInvalid)
        case (401, "DEVICE_DEREGISTERED"), (403, "DEVICE_DEREGISTERED"):
            if await client.isActive(registration) == false { credentials.clear() }
            return .stop(.deregistered)
        case (401, "VIEWER_CANNOT_UPLOAD"), (403, "VIEWER_CANNOT_UPLOAD"):
            return .stop(.viewerCannotUpload)
        case (401, "INVALID_TOKEN"), (403, "INVALID_TOKEN"):
            credentials.clear()
            return .stop(.invalidToken)
        default:
            let message = json?["message"] as? String ?? json?["error"] as? String ?? ""
            return .stop(.failed(uploaded: 0, reason: "HTTP \(status) \(message)".trimmingCharacters(in: .whitespaces)))
        }
    }

    private func recordSuccess(count: Int) {
        let total = (Int((try? queue.meta("totalUploaded")) ?? nil ?? "0") ?? 0) + count
        try? queue.setMeta("totalUploaded", String(total))
        try? queue.setMeta("lastUploadAt", String(now().timeIntervalSince1970))
    }

    private func date(meta key: String) -> Date? {
        guard let text = (try? queue.meta(key)) ?? nil, let seconds = TimeInterval(text) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// True when the server gave a verdict on the records themselves: 207, or
    /// a 4xx other than the ones about authorization, quota, registration,
    /// timeouts and throttling (401, 402, 403, 408, 410, 425, 429).
    static func isDefinitiveRejection(_ status: Int) -> Bool {
        status == 207 || ((400...499).contains(status) && ![401, 402, 403, 408, 410, 425, 429].contains(status))
    }

    /// Retry-After in seconds, defaulting to 24 h and clamped to 1 s ... 7 days.
    /// The HTTP-date form counts as missing, as in the Android app (the server
    /// sends seconds).
    static func retryAfterSeconds(_ header: String?) -> TimeInterval {
        let parsed = header.flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }.map(TimeInterval.init)
        return min(max(parsed ?? defaultQuotaRetryAfter, 1), maxQuotaRetryAfter)
    }

    /// `{"device_token":...,"batch_id":...,"records":[{"type":...,"messages":[...]}]}`,
    /// with the records grouped by type in order of first appearance and the
    /// stored JSON embedded as is.
    static func body(token: String, batchID: String, entries: [NSAnalyticsQueue.Entry]) -> Data {
        var order: [String] = []
        var groups: [String: [String]] = [:]
        for entry in entries {
            if groups[entry.type] == nil { order.append(entry.type) }
            groups[entry.type, default: []].append(entry.json)
        }
        var writer = NSJSONWriter()
        writer.beginObject()
        writer.key("device_token")
        writer.string(token)
        writer.key("batch_id")
        writer.string(batchID)
        writer.key("records")
        var text = writer.output + "["
        text += order.map { type in
            var item = NSJSONWriter()
            item.beginObject()
            item.key("type")
            item.string(type)
            item.key("messages")
            return item.output + "[" + groups[type]!.joined(separator: ",") + "]}"
        }.joined(separator: ",")
        return Data((text + "]}").utf8)
    }
}
