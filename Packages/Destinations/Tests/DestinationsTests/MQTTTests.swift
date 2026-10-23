import Foundation
import MQTTNIO
import NIOCore
import NIOTransportServices
import NSMessaging
import Testing
@testable import Destinations

#if os(macOS)
/// Runs a private mosquitto broker on a free local port for one test.
final class LocalBroker: @unchecked Sendable {
    static let path = "/opt/homebrew/sbin/mosquitto"
    static var available: Bool { FileManager.default.isExecutableFile(atPath: path) }

    let port: Int
    private var process: Process?
    private let config: URL

    init() throws {
        port = try Self.freePort()
        config = FileManager.default.temporaryDirectory.appendingPathComponent("mosquitto-\(port).conf")
        try "listener \(port) 127.0.0.1\nallow_anonymous true\npersistence false\n".write(to: config, atomically: true, encoding: .utf8)
    }

    func start() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.path)
        process.arguments = ["-c", config.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        self.process = process
        for _ in 0..<50 where !Self.accepts(port: port) { try await Task.sleep(for: .milliseconds(100)) }
    }

    func stop() {
        process?.terminate()
        process?.waitUntilExit()
        process = nil
    }

    deinit {
        stop()
        try? FileManager.default.removeItem(at: config)
    }

    static func freePort() throws -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, length) } }
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) } }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    static func accepts(port: Int) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port).bigEndian
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}

/// Subscribes to everything on the broker and collects what arrives.
final class Subscriber: @unchecked Sendable {
    private let client: MQTTClient
    private let lock = NSLock()
    private var messages: [(topic: String, payload: String)] = []

    init(port: Int) async throws {
        client = MQTTClient(host: "127.0.0.1", port: port, identifier: "test-subscriber-\(UUID().uuidString.prefix(8))",
                            eventLoopGroupProvider: .shared(NIOTSEventLoopGroup.singleton))
        try await client.connect()
        client.addPublishListener(named: "collect") { [weak self] result in
            guard case .success(let info) = result else { return }
            self?.lock.withLock { self?.messages.append((info.topicName, String(buffer: info.payload))) }
        }
        _ = try await client.subscribe(to: [MQTTSubscribeInfo(topicFilter: "#", qos: .atLeastOnce)])
    }

    var received: [(topic: String, payload: String)] { lock.withLock { messages } }

    func waitFor(count: Int, timeout: Duration = .seconds(10)) async throws -> [(topic: String, payload: String)] {
        let deadline = ContinuousClock.now + timeout
        while received.count < count && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        return received
    }

    func close() async {
        try? await client.disconnect()
        try? await client.shutdown()
    }
}

@Suite("MQTT destination", .serialized, .enabled(if: LocalBroker.available))
struct MQTTTests {
    @Test("Publishes each record type to the NS Messaging topic under the prefix")
    func topics() async throws {
        let broker = try LocalBroker()
        try await broker.start()
        defer { broker.stop() }
        let subscriber = try await Subscriber(port: broker.port)
        let destination = MQTTDestination(config: MQTTConfig(host: "127.0.0.1", port: broker.port, useTLS: false, clientID: "ns-test-1",
                                                             topicPrefix: "site-a/"))
        try await destination.start(Samples.session(Samples.tempDirectory()))
        await destination.accept([Samples.apRecord(), Samples.probeRecord(), Samples.bleRecord(), Samples.statusRecord(),
                                  Samples.clientRecord(), SurveyRecord(boardID: "x", kind: .rawFrame(.init(), timestamp: Date()))])
        let received = try await subscriber.waitFor(count: 4)
        await destination.stop()
        await subscriber.close()

        #expect(Set(received.map(\.topic)) == [
            "site-a/80211_beacon_message", "site-a/80211_probe_request_message", "site-a/bluetooth_message",
            "site-a/device_status_message",
        ])
        let beacon = try #require(received.first { $0.topic.hasSuffix("80211_beacon_message") })
        let expected = Samples.apRecord().kind
        if case .ap(let ns, _) = expected {
            #expect(beacon.payload == ns.stamped(deviceName: "Field kit 2").jsonString())
        }
        #expect(beacon.payload.contains(#""deviceName":"Field kit 2""#))
        let snapshot = await destination.snapshot()
        #expect(snapshot.recordsAccepted == 4)
        #expect(snapshot.status == .off)
    }

    @Test("Station records go only to the experimental topic, and only when enabled")
    func stations() async throws {
        let broker = try LocalBroker()
        try await broker.start()
        defer { broker.stop() }
        let subscriber = try await Subscriber(port: broker.port)
        let destination = MQTTDestination(config: MQTTConfig(host: "127.0.0.1", port: broker.port, useTLS: false, clientID: "ns-test-2",
                                                             streamStationRecords: true))
        try await destination.start(Samples.session(Samples.tempDirectory(), deviceName: ""))
        await destination.accept([Samples.clientRecord()])
        let received = try await subscriber.waitFor(count: 1)
        await destination.stop()
        await subscriber.close()
        #expect(received.map(\.topic) == ["80211_station_message"])
        // With no device name the client ID is stamped, as on Android.
        #expect(received.first?.payload.contains(#""deviceName":"ns-test-2""#) == true)
        #expect(received.first?.payload.contains(#""messageType":"WifiStationRecord""#) == true)
    }

    @Test("Queues while the broker is down, drops past the limit, then delivers on connect")
    func queueAndReconnect() async throws {
        let broker = try LocalBroker()
        let destination = MQTTDestination(
            config: MQTTConfig(host: "127.0.0.1", port: broker.port, useTLS: false, clientID: "ns-test-3", queueLimit: 3,
                               connectTimeout: .milliseconds(500)),
            maxBackoff: .milliseconds(300)
        )
        try await destination.start(Samples.session(Samples.tempDirectory()))
        await destination.accept((1...5).map { Samples.apRecord(Int32($0)) })
        try await Task.sleep(for: .milliseconds(800))
        var snapshot = await destination.snapshot()
        #expect(snapshot.queueDepth == 3)
        #expect(snapshot.droppedRecords == 2)
        #expect(snapshot.status != .running)
        #expect(snapshot.lastError != nil)

        try await broker.start()
        defer { broker.stop() }
        let deadline = ContinuousClock.now + .seconds(10)
        while await destination.publishedCount < 3 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        snapshot = await destination.snapshot()
        #expect(snapshot.status == .running)
        #expect(snapshot.queueDepth == 0)
        #expect(await destination.publishedCount == 3)
        await destination.stop()
    }

    @Test("Stop does not wait for an unreachable broker")
    func fastStop() async throws {
        let port = try LocalBroker.freePort()
        let destination = MQTTDestination(config: MQTTConfig(host: "127.0.0.1", port: port, useTLS: false, clientID: "ns-test-4"))
        try await destination.start(Samples.session(Samples.tempDirectory()))
        await destination.accept([Samples.apRecord()])
        try await Task.sleep(for: .milliseconds(200))
        let started = ContinuousClock.now
        await destination.stop()
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(await destination.snapshot().status == .off)
    }

    @Test("Settings the Android app rejects are rejected")
    func validation() {
        #expect(throws: DestinationError.self) { try MQTTConfig(host: " ", clientID: "a").validate() }
        #expect(throws: DestinationError.self) { try MQTTConfig(host: "h", port: 0, clientID: "a").validate() }
        #expect(throws: DestinationError.self) { try MQTTConfig(host: "h", clientID: "").validate() }
        #expect(throws: DestinationError.self) { try MQTTConfig(host: "h", clientID: "a", topicPrefix: "a/#").validate() }
        #expect(throws: DestinationError.self) { try MQTTConfig(host: "h", clientID: "a", qos: 3).validate() }
        #expect(throws: Never.self) { try MQTTConfig(host: "h", clientID: "a", topicPrefix: "a/b/").validate() }
        let defaults = MQTTConfig(host: "h", clientID: "a")
        #expect(defaults.port == 8883 && defaults.useTLS)
    }
}

#endif

@Suite("Stream queue")
struct StreamQueueTests {
    @Test("A limit counts queued and in-flight messages; 0 is unbounded")
    func limits() {
        var queue = StreamQueue<Int>(limit: 3)
        let accepted = (1...4).map { queue.append($0) }
        #expect(accepted == [true, true, true, false])
        #expect(queue.dropped == 1)
        let taken = queue.take(2)
        #expect(taken == [1, 2])
        #expect(queue.depth == 3)
        let fifth = queue.append(5)
        #expect(!fifth)
        queue.requeue([2])
        queue.finished(1)
        #expect(queue.depth == 2)
        let rest = queue.take(10)
        #expect(rest == [2, 3])
        queue.finished(2)
        #expect(queue.isEmpty && queue.depth == 0)

        var unbounded = StreamQueue<Int>(limit: 0)
        for value in 0..<50_000 { unbounded.append(value) }
        #expect(unbounded.depth == 50_000 && unbounded.dropped == 0)
        var held = StreamQueue<Int>(limit: 0)
        for value in 0..<5 { held.append(value, limitOverride: 3) }
        #expect(held.depth == 3 && held.dropped == 2)
        let first = unbounded.take(2000)
        let next = unbounded.take(1)
        #expect(first.count == 2000 && next == [2000])
    }
}
