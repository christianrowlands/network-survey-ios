import Foundation
import NSMessaging
import Testing
@testable import Destinations

/// A URLProtocol that answers every request from a handler and records what was sent.
final class StubServer: URLProtocol, @unchecked Sendable {
    struct Sent: Sendable {
        let request: URLRequest
        let body: Data
        var json: [String: Any] { ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:] }
    }

    typealias Handler = @Sendable (URLRequest, Data) -> (Int, [String: String], Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var log: [Sent] = []

    static func install(_ handler: @escaping Handler) {
        lock.withLock {
            self.handler = handler
            log = []
        }
    }

    static var sent: [Sent] { lock.withLock { log } }

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let (handler, request) = Self.lock.withLock { (Self.handler, self.request) }
        Self.lock.withLock { Self.log.append(Sent(request: request, body: body)) }
        guard let handler else { return client!.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)) }
        let (status, headers, data) = handler(request, body)
        if status == 0 { return client!.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client!.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client!.urlProtocol(self, didLoad: data)
        client!.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    /// A successful upload answer.
    static func completed(_ body: Data, skipped: Int = 0) -> (Int, [String: String], Data) {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let count = (json["records"] as? [[String: Any]] ?? []).reduce(0) { $0 + (($1["messages"] as? [Any])?.count ?? 0) }
        return (200, [:], Self.json([
            "batch_id": json["batch_id"] ?? "", "status": "completed", "processed": count - skipped, "skipped": skipped,
            "failed": 0, "total_records": count, "workspace_name": "Example Workspace",
        ]))
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_792_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

@Suite("NS Analytics", .serialized)
struct NSAnalyticsTests {
    static let api = URL(string: "https://ingest.example.net")!
    static let registration = NSAnalyticsRegistration(
        deviceToken: "device-token-1", deviceID: "reg-1", workspaceID: "ws-1", workspaceName: "Old Name", apiURL: api
    )

    func makeUploader(
        registered: Bool = true, clock: TestClock = TestClock(), transport: (any NSAnalyticsTransport)? = nil
    ) throws -> (NSAnalyticsUploader, InMemoryCredentialStore) {
        let credentials = InMemoryCredentialStore(registered ? Self.registration : nil)
        let uploader = NSAnalyticsUploader(
            queue: try NSAnalyticsQueue(url: nil), credentials: credentials,
            transport: transport ?? URLSessionTransport(session: URLSession(configuration: StubServer.configuration)),
            now: { clock.now }
        )
        return (uploader, credentials)
    }

    func enqueue(_ uploader: NSAnalyticsUploader, _ count: Int, type: String = "wifi") throws {
        let json = WifiBeaconRecord(data: WifiBeaconRecordData()).jsonString()
        try uploader.queue.enqueue(Array(repeating: (type: type, json: json), count: count))
    }

    @Test("Registration link parsing follows the Android checks")
    func links() throws {
        let link = try NSAnalyticsLink(url: URL(string:
            "https://networksurvey.app/app/register?token=abc&workspace_id=ws-1&api_url=https%3A%2F%2Fingest.example.net&workspace_name=Field%20Team")!)
        #expect(link == NSAnalyticsLink(token: "abc", workspaceID: "ws-1", apiURL: Self.api, workspaceName: "Field Team"))
        func problem(_ text: String) -> NSAnalyticsLink.Problem? {
            do { _ = try NSAnalyticsLink(url: URL(string: text)!); return nil } catch { return error }
        }
        let base = "https://networksurvey.app/app/register?"
        #expect(problem("https://example.com/app/register?token=a") == .notARegistrationLink)
        #expect(problem(base + "workspace_id=w&api_url=https://a.example") == .missingToken)
        #expect(problem(base + "token=t&api_url=https://a.example") == .missingWorkspace)
        #expect(problem(base + "token=t&workspace_id=w") == .missingServer)
        #expect(problem(base + "token=t&workspace_id=w&api_url=http://a.example") == .serverNotHTTPS)
        #expect(problem(base + "token=t&workspace_id=w&api_url=https://192.168.1.10") == .localServer)
        #expect(problem(base + "token=t&workspace_id=w&api_url=https://localhost") == .localServer)
        #expect(problem(base + "token=t&workspace_id=w&api_url=https://172.20.0.1") == .localServer)
        #expect(problem(base + "token=t&workspace_id=w&api_url=https://a.example&workspace_name=" + String(repeating: "x", count: 101))
            == .nameTooLong)
    }

    @Test("Registration posts the device fields and stores the answer")
    func register() async throws {
        StubServer.install { request, _ in
            (200, [:], StubServer.json(["device_id": "reg-9", "device_token": "tok-9", "workspace_id": "ws-1",
                                        "workspace_name": "Field Team", "message": "Device registered successfully"]))
        }
        let client = NSAnalyticsClient(transport: URLSessionTransport(session: URLSession(configuration: StubServer.configuration)))
        let device = NSAnalyticsClient.DeviceInfo(deviceID: "8C2E1F7A", deviceName: "Field kit 2", deviceModel: "iPhone17,3",
                                                  osVersion: "iOS 18.0", appVersion: "1.0.0")
        let registration = try await client.register(NSAnalyticsLink(token: "abc", workspaceID: "ws-1", apiURL: Self.api), device: device)
        #expect(registration == NSAnalyticsRegistration(deviceToken: "tok-9", deviceID: "reg-9", workspaceID: "ws-1",
                                                        workspaceName: "Field Team", apiURL: Self.api))
        let sent = try #require(StubServer.sent.first)
        #expect(sent.request.url?.absoluteString == "https://ingest.example.net/api/v1/device/register")
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.json as? [String: String] == [
            "token": "abc", "device_id": "8C2E1F7A", "device_name": "Field kit 2", "device_model": "iPhone17,3",
            "os_version": "iOS 18.0", "app_version": "1.0.0",
        ])
    }

    @Test("Registration failures are classified like the Android app")
    func registrationErrors() {
        func classify(_ status: Int, _ body: [String: Any]) -> NSAnalyticsRegistrationError {
            .classify(status: status, body: StubServer.json(body))
        }
        #expect(classify(400, ["error": "Token expired"]) == .codeRejected)
        #expect(classify(400, ["error": "Device limit reached (5/5)"]) == .deviceLimit)
        #expect(classify(403, ["error": "x", "error_code": "LICENSE_EXPIRED"]) == .license)
        #expect(classify(403, ["error": "x", "error_code": "LICENSE_DEVICE_LIMIT"]) == .deviceLimit)
        #expect(classify(401, [:]) == .codeRejected)
        #expect(classify(502, [:]) == .server)
        #expect(classify(400, ["error": "Invalid request body"]) == .other("Invalid request body"))
    }

    @Test("Uploads in batches of up to 1000, grouped by type, until the queue is empty")
    func batches() async throws {
        StubServer.install { _, body in StubServer.completed(body) }
        let (uploader, credentials) = try makeUploader()
        try enqueue(uploader, 1200, type: "wifi")
        try enqueue(uploader, 700, type: "bluetooth")
        try enqueue(uploader, 100, type: "device_status")
        #expect(await uploader.state().pending == 2000)
        #expect(await uploader.uploadPending() == .uploaded(records: 2000))
        let sent = StubServer.sent
        #expect(sent.count == 2)
        #expect(sent[0].request.value(forHTTPHeaderField: "Authorization") == "Bearer device-token-1")
        #expect(sent[0].request.url?.path == "/api/v1/device/upload")
        let first = try #require(sent[0].json["records"] as? [[String: Any]])
        #expect(first.map { $0["type"] as? String } == ["wifi"])
        let second = try #require(sent[1].json["records"] as? [[String: Any]])
        #expect(second.map { $0["type"] as? String } == ["wifi", "bluetooth", "device_status"])
        #expect(second.map { ($0["messages"] as? [Any])?.count } == [200, 700, 100])
        #expect(sent[0].json["device_token"] as? String == "device-token-1")
        #expect(sent[0].json["batch_id"] as? String != sent[1].json["batch_id"] as? String)
        let message = try #require((first[0]["messages"] as? [[String: Any]])?.first)
        #expect(message["messageType"] as? String == "WifiBeaconRecord")
        let state = await uploader.state()
        #expect(state.pending == 0 && state.totalUploaded == 2000 && state.lastUploadAt != nil)
        #expect(credentials.load()?.workspaceName == "Example Workspace")
    }

    @Test("Records the server skips count as done")
    func skipped() async throws {
        StubServer.install { _, body in StubServer.completed(body, skipped: 5) }
        let (uploader, _) = try makeUploader()
        try enqueue(uploader, 5, type: NSAnalyticsRecordType.wifiProbeRequest)
        #expect(await uploader.uploadPending() == .uploaded(records: 5))
        #expect(await uploader.state().pending == 0)
    }

    @Test("Definitive rejections count retries and drop records after 3; outages never count")
    func retries() async throws {
        StubServer.install { _, _ in (400, [:], StubServer.json(["error": "Invalid JSON format"])) }
        let (uploader, _) = try makeUploader()
        try enqueue(uploader, 3)
        for attempt in 1...4 {
            guard case .failed = await uploader.uploadPending() else { Issue.record("attempt \(attempt) should fail"); return }
            #expect(Set(try uploader.queue.retryCounts().values) == [attempt])
        }
        // The fifth run drops the records past the cap instead of sending them.
        #expect(await uploader.uploadPending() == .uploaded(records: 0))
        #expect(StubServer.sent.count == 4)

        for status in [500, 503, 408, 429, 0] {
            StubServer.install { _, _ in (status, [:], Data()) }
            try enqueue(uploader, 1)
            guard case .failed = await uploader.uploadPending() else { Issue.record("\(status) should fail"); return }
            #expect(Set(try uploader.queue.retryCounts().values) == [0], "HTTP \(status)")
        }
        StubServer.install { _, _ in (207, [:], StubServer.json(["status": "completed_with_errors", "failed": 1])) }
        _ = await uploader.uploadPending()
        #expect(Set(try uploader.queue.retryCounts().values) == [1])
        #expect(NSAnalyticsUploader.isDefinitiveRejection(422))
        #expect(!NSAnalyticsUploader.isDefinitiveRejection(425))
    }

    @Test("402 pauses uploads until Retry-After")
    func quota() async throws {
        let clock = TestClock()
        StubServer.install { _, _ in
            (402, ["Retry-After": "120"], StubServer.json([
                "error": "Quota exceeded", "error_code": "QUOTA_EXCEEDED", "message": "Monthly limit reached",
                "current_usage": 1000, "max_records": 1000, "limit_type": "monthly", "web_url": "https://example.net/billing",
            ]))
        }
        let (uploader, _) = try makeUploader(clock: clock)
        try enqueue(uploader, 2)
        guard case .quotaExceeded(let info) = await uploader.uploadPending() else { Issue.record("expected a quota pause"); return }
        #expect(info.pausedUntil == clock.now.addingTimeInterval(120))
        #expect(info.maxRecords == 1000 && info.message == "Monthly limit reached")
        #expect(await uploader.uploadPending() == .paused(until: clock.now.addingTimeInterval(120)))
        #expect(StubServer.sent.count == 1)
        #expect(Set(try uploader.queue.retryCounts().values) == [0])

        StubServer.install { _, body in StubServer.completed(body) }
        clock.advance(121)
        #expect(await uploader.uploadPending() == .uploaded(records: 2))
        #expect(await uploader.state().pausedUntil == nil)

        #expect(NSAnalyticsUploader.retryAfterSeconds(nil) == 86_400)
        #expect(NSAnalyticsUploader.retryAfterSeconds("abc") == 86_400)
        #expect(NSAnalyticsUploader.retryAfterSeconds("0") == 1)
        #expect(NSAnalyticsUploader.retryAfterSeconds(" 30 ") == 30)
        #expect(NSAnalyticsUploader.retryAfterSeconds("99999999") == 7 * 86_400)
    }

    @Test("Ignoring the pause sends anyway")
    func manualResume() async throws {
        let clock = TestClock()
        StubServer.install { _, _ in (402, [:], StubServer.json(["error_code": "QUOTA_EXCEEDED", "message": "m"])) }
        let (uploader, _) = try makeUploader(clock: clock)
        try enqueue(uploader, 1)
        _ = await uploader.uploadPending()
        StubServer.install { _, body in StubServer.completed(body) }
        #expect(await uploader.uploadPending(ignoringPause: true) == .uploaded(records: 1))
    }

    @Test("Registration problems: 410 and invalid token drop it, viewer keeps it, deregistered checks status")
    func registrationProblems() async throws {
        let cases: [(Int, String, NSAnalyticsUploader.Outcome, Bool?, Bool)] = [
            (410, "REGISTRATION_INVALID", .registrationInvalid, nil, false),
            (401, "INVALID_TOKEN", .invalidToken, nil, false),
            (403, "VIEWER_CANNOT_UPLOAD", .viewerCannotUpload, nil, true),
            (403, "DEVICE_DEREGISTERED", .deregistered, false, false),
            (403, "DEVICE_DEREGISTERED", .deregistered, true, true),
        ]
        for (status, code, outcome, active, keeps) in cases {
            StubServer.install { request, _ in
                if request.url?.path == "/api/v1/device/status" {
                    return (200, [:], StubServer.json(["device_id": "reg-1", "workspace_id": "ws-1", "is_active": active ?? true]))
                }
                return (status, [:], StubServer.json(["error": "x", "error_code": code]))
            }
            let (uploader, credentials) = try makeUploader()
            try enqueue(uploader, 1)
            #expect(await uploader.uploadPending() == outcome, "\(status) \(code)")
            #expect((credentials.load() != nil) == keeps, "\(status) \(code)")
            #expect(Set(try uploader.queue.retryCounts().values) == [0], "records stay for a later registration")
        }
        let (unregistered, _) = try makeUploader(registered: false)
        #expect(await unregistered.uploadPending() == .notRegistered)
    }

    @Test("File-based upload tasks work and late answers settle their batch")
    func backgroundTransport() async throws {
        StubServer.install { _, body in StubServer.completed(body) }
        let transport = BackgroundUploadTransport(configuration: StubServer.configuration,
                                                  directory: Samples.tempDirectory())
        let (uploader, _) = try makeUploader(transport: transport)
        try enqueue(uploader, 10)
        #expect(await uploader.uploadPending() == .uploaded(records: 10))
        #expect(StubServer.sent.first?.json["records"] != nil)

        // An upload that finished while the app was not waiting for it.
        try enqueue(uploader, 3)
        let entries = try uploader.queue.uploadable(limit: 10, maxRetryCount: 3)
        try uploader.queue.beginBatch("late-batch", ids: entries.map(\.id))
        #expect(await uploader.state().pending == 3)
        let response = HTTPURLResponse(url: Self.api, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let body = StubServer.json(["status": "completed", "processed": 3, "failed": 0])
        await uploader.completeBackgroundUpload(taskID: "late-batch", result: .success((body, response)))
        #expect(await uploader.state().pending == 0)
    }

    @Test("Records without a location and records while unregistered are not queued")
    func skipsUnusableRecords() async throws {
        let (uploader, credentials) = try makeUploader()
        let destination = NSAnalyticsDestination(uploader: uploader, config: NSAnalyticsConfig(uploadInterval: nil, uploadOnStop: false))
        try await destination.start(Samples.session(Samples.tempDirectory()))
        let unlocated = SurveyRecord(boardID: "NS-1A2B", kind: .ap(
            WifiBeaconRecord(ap: Samples.ap, context: Samples.context(9, location: false)), Samples.ap
        ))
        await destination.accept([Samples.apRecord(), unlocated])
        #expect(await destination.snapshot().recordsAccepted == 1)

        credentials.clear()
        await destination.accept([Samples.apRecord(2)])
        let snapshot = await destination.snapshot()
        #expect(snapshot.recordsAccepted == 1 && snapshot.queueDepth == 1)
        #expect(snapshot.status == .error(NSAnalyticsDestination.notRegistered))
        await destination.stop()

        let keepAll = NSAnalyticsDestination(uploader: try makeUploader().0, config: NSAnalyticsConfig(
            uploadInterval: nil, uploadOnStop: false, requireLocation: false
        ))
        try await keepAll.start(Samples.session(Samples.tempDirectory()))
        await keepAll.accept([unlocated])
        #expect(await keepAll.snapshot().recordsAccepted == 1)
    }

    @Test("Registration goes through the foreground session, never the background one")
    func registrationBypassesBackground() async throws {
        StubServer.install { _, _ in
            (200, [:], StubServer.json(["device_id": "reg-9", "device_token": "tok-9", "workspace_id": "ws-1"]))
        }
        // The "background" configuration cannot reach the stub; only the fallback session can.
        let transport = BackgroundUploadTransport(
            configuration: .ephemeral, fallbackSession: URLSession(configuration: StubServer.configuration),
            directory: Samples.tempDirectory()
        )
        let device = NSAnalyticsClient.DeviceInfo(deviceID: "d", deviceName: "n", deviceModel: "m", osVersion: "o", appVersion: "a")
        let registration = try await NSAnalyticsClient(transport: transport)
            .register(NSAnalyticsLink(token: "abc", workspaceID: "ws-1", apiURL: Self.api), device: device)
        #expect(registration.deviceToken == "tok-9")
    }

    @Test("Late answers are kept until the orphan handler is set")
    func orphanBuffering() async throws {
        let transport = BackgroundUploadTransport(configuration: StubServer.configuration, directory: Samples.tempDirectory())
        StubServer.install { _, body in StubServer.completed(body) }
        // A finished task nobody waits for: simulate the delegate callback after a relaunch.
        let session = URLSession(configuration: StubServer.configuration)
        var request = URLRequest(url: Self.api.appendingPathComponent("api/v1/device/upload"))
        request.httpMethod = "POST"
        let task = session.uploadTask(with: request, from: Data("{}".utf8))
        task.taskDescription = "batch-7"
        let done = AsyncStream<Void>.makeStream()
        let delegate = CompletionWatcher { done.continuation.yield() }
        task.delegate = delegate
        task.resume()
        for await _ in done.stream { break }
        transport.urlSession(session, task: task, didCompleteWithError: nil)

        let received = Received.Box()
        transport.orphanHandler = { taskID, _ in received.add(taskID) }
        #expect(received.values == ["batch-7"])
        transport.orphanHandler = { taskID, _ in received.add(taskID) }
        #expect(received.values == ["batch-7"]) // delivered once
    }

    @Test("The events-finished handler runs exactly once, even if set after the events finished")
    func eventsFinished() {
        let session = URLSession(configuration: .ephemeral)
        let calls = Received.Box()
        let early = BackgroundUploadTransport(configuration: .ephemeral, directory: Samples.tempDirectory())
        early.urlSessionDidFinishEvents(forBackgroundURLSession: session)
        early.eventsFinished = { calls.add("early") }
        #expect(calls.values == ["early"])
        #expect(early.eventsFinished == nil)
        early.eventsFinished = { calls.add("again") } // no pending event: stored, not called
        #expect(calls.values == ["early"])

        let late = BackgroundUploadTransport(configuration: .ephemeral, directory: Samples.tempDirectory())
        late.eventsFinished = { calls.add("late") }
        late.urlSessionDidFinishEvents(forBackgroundURLSession: session)
        late.urlSessionDidFinishEvents(forBackgroundURLSession: session)
        #expect(calls.values == ["early", "late"])
    }

    @Test("The destination queues the accepted types and uploads when the survey stops")
    func destination() async throws {
        StubServer.install { _, body in StubServer.completed(body, skipped: 0) }
        let (uploader, _) = try makeUploader()
        let plain = NSAnalyticsDestination(uploader: uploader, config: NSAnalyticsConfig(uploadInterval: nil, uploadOnStop: false))
        try await plain.start(Samples.session(Samples.tempDirectory()))
        await plain.accept([Samples.apRecord(), Samples.bleRecord(), Samples.statusRecord(), Samples.probeRecord(), Samples.clientRecord()])
        #expect(await plain.snapshot().recordsAccepted == 3)
        #expect(await plain.snapshot().queueDepth == 3)
        await plain.stop()

        let experimental = NSAnalyticsDestination(uploader: uploader, config: NSAnalyticsConfig(
            uploadInterval: nil, uploadProbeRequests: true, uploadStationRecords: true, uploadOnStop: true
        ))
        try await experimental.start(Samples.session(Samples.tempDirectory()))
        await experimental.accept([Samples.probeRecord(), Samples.clientRecord()])
        await experimental.stop()
        let deadline = ContinuousClock.now + .seconds(5)
        while await uploader.state().pending > 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let types = StubServer.sent.flatMap { ($0.json["records"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String } }
        #expect(types == ["wifi", "bluetooth", "device_status", "wifi_probe_request", "wifi_station"])
        #expect(await uploader.state().totalUploaded == 5)
    }
}

final class CompletionWatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let done: @Sendable () -> Void
    init(_ done: @escaping @Sendable () -> Void) { self.done = done }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { done() }
}

extension Received {
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) { lock.withLock { items.append(item) } }
        var values: [String] { lock.withLock { items } }
    }
}
