import Foundation
import MQTTNIO
import NIOCore
import NIOTransportServices
import NSMessaging

public struct MQTTConfig: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var useTLS: Bool
    public var username: String?
    public var password: String?
    public var clientID: String
    /// Put in front of every topic name as it is, for example "site-a/".
    public var topicPrefix: String
    /// 0, 1 or 2. The Android app defaults to 1 (at least once).
    public var qos: UInt8
    /// Most messages queued while the broker is slow or unreachable; 0 means
    /// unbounded (still capped at 20,000 until the broker was reached once).
    public var queueLimit: Int
    /// Experimental: also publish station (client) records.
    public var streamStationRecords: Bool
    /// Network.framework waits for an unreachable broker instead of failing,
    /// so this bounds each connection attempt.
    public var connectTimeout: Duration

    /// Defaults to TLS on port 8883, the app's MQTT setting defaults.
    public init(
        host: String, port: Int = 8883, useTLS: Bool = true, username: String? = nil, password: String? = nil,
        clientID: String, topicPrefix: String = "", qos: UInt8 = 1, queueLimit: Int = 20_000,
        streamStationRecords: Bool = false, connectTimeout: Duration = .seconds(10)
    ) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.username = username
        self.password = password
        self.clientID = clientID
        self.topicPrefix = topicPrefix
        self.qos = qos
        self.queueLimit = queueLimit
        self.streamStationRecords = streamStationRecords
        self.connectTimeout = connectTimeout
    }

    /// The checks the Android app's MQTT library makes before connecting.
    public func validate() throws(DestinationError) {
        if host.trimmingCharacters(in: .whitespaces).isEmpty { throw .invalidSettings("The MQTT broker host is empty") }
        if !(1...65535).contains(port) { throw .invalidSettings("The MQTT broker port is not valid: \(port)") }
        if clientID.isEmpty { throw .invalidSettings("The MQTT client ID is empty") }
        if topicPrefix.contains("#") || topicPrefix.contains("+") {
            throw .invalidSettings("The MQTT topic prefix can't contain the wildcards # or +")
        }
        if qos > 2 { throw .invalidSettings("The MQTT QoS must be 0, 1 or 2") }
    }
}

extension Duration {
    var milliseconds: Int64 { components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000 }
}

public enum DestinationError: Error, Equatable, Sendable {
    case invalidSettings(String)
}

/// Topic names from the NS Messaging AsyncAPI channels.
public enum MQTTTopic {
    public static let wifiBeacon = "80211_beacon_message"
    public static let wifiProbeRequest = "80211_probe_request_message"
    public static let bluetooth = "bluetooth_message"
    public static let deviceStatus = "device_status_message"
    /// Experimental, proposed: not in NS Messaging 2.6.0.
    public static let wifiStation = "80211_station_message"
}

/// Publishes NS Messaging JSON to an MQTT broker (MQTT 3.1.1, persistent
/// session), reconnecting with backoff and queueing while disconnected.
public actor MQTTDestination: Destination {
    public nonisolated let kind = DestinationKind.mqtt

    private struct Message: Sendable {
        let topic: String
        let payload: ByteBuffer
    }

    /// Until the broker was reached once, an unbounded queue holds at most this many.
    static let holdLimit = 20_000
    private static let batchSize = 64

    private let config: MQTTConfig
    private let maxBackoff: Duration
    private let drainTimeout: Duration
    private var client: MQTTClient?
    private var session: SessionInfo?
    private var deviceName = ""
    private var queue: StreamQueue<Message>
    private var runner: Task<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var connected = false
    private var connectedOnce = false
    private var stopping = false
    private var recordsAccepted = 0
    private var published = 0
    private var lastError: String?
    private var lastSuccessAt: Date?

    public init(config: MQTTConfig, maxBackoff: Duration = .seconds(20), drainTimeout: Duration = .seconds(5)) {
        self.config = config
        self.maxBackoff = maxBackoff
        self.drainTimeout = drainTimeout
        queue = StreamQueue(limit: max(0, config.queueLimit))
    }

    public func start(_ session: SessionInfo) async throws {
        try config.validate()
        self.session = session
        deviceName = session.deviceName.isEmpty ? config.clientID : session.deviceName
        stopping = false
        connectedOnce = false
        let tls: TSTLSConfiguration? = config.useTLS ? TSTLSConfiguration() : nil
        client = MQTTClient(
            host: config.host, port: config.port, identifier: config.clientID,
            eventLoopGroupProvider: .shared(NIOTSEventLoopGroup.singleton),
            configuration: .init(
                version: .v3_1_1, connectTimeout: .milliseconds(config.connectTimeout.milliseconds),
                timeout: .seconds(10), userName: config.username, password: config.password,
                useSSL: config.useTLS, tlsConfiguration: tls.map { .ts($0) }
            )
        )
        runner = Task { await self.run() }
    }

    public func accept(_ records: [SurveyRecord]) async {
        guard session != nil, !stopping else { return }
        let limitOverride = connectedOnce ? nil : Self.holdLimit
        for record in records {
            guard let (topic, json) = encode(record) else { continue }
            var buffer = ByteBufferAllocator().buffer(capacity: json.utf8.count)
            buffer.writeString(json)
            if queue.append(Message(topic: config.topicPrefix + topic, payload: buffer), limitOverride: limitOverride) {
                recordsAccepted += 1
            }
        }
        wake()
    }

    public func stop() async {
        guard let runner else { return }
        stopping = true
        wake()
        if connected {
            // Send what is queued, for up to drainTimeout.
            let timeout = Task { [drainTimeout] in try? await Task.sleep(for: drainTimeout); runner.cancel() }
            await runner.value
            timeout.cancel()
        } else {
            // Nothing can be sent: don't wait out a backoff or a connect attempt.
            runner.cancel()
        }
        self.runner = nil
        if let client {
            if connected { try? await client.disconnect() }
            try? await client.shutdown()
        }
        client = nil
        connected = false
        session = nil
    }

    public func snapshot() async -> DestinationSnapshot {
        let status: DestinationStatus
        if session == nil {
            status = .off
        } else if connected {
            status = .running
        } else {
            status = lastError.map { .error($0) } ?? .starting
        }
        var snapshot = DestinationSnapshot(status: status)
        snapshot.recordsAccepted = recordsAccepted
        snapshot.queueDepth = queue.depth
        snapshot.droppedRecords = queue.dropped
        snapshot.lastError = lastError
        snapshot.lastSuccessAt = lastSuccessAt
        return snapshot
    }

    /// Messages sent to the broker so far (for tests and diagnostics).
    public var publishedCount: Int { published }

    private func encode(_ record: SurveyRecord) -> (String, String)? {
        switch record.kind {
        case .ap(let ns, _): (MQTTTopic.wifiBeacon, ns.stamped(deviceName: deviceName).jsonString())
        case .probe(let ns, _): (MQTTTopic.wifiProbeRequest, ns.stamped(deviceName: deviceName).jsonString())
        case .ble(let ns, _): (MQTTTopic.bluetooth, ns.stamped(deviceName: deviceName).jsonString())
        case .deviceStatus(let ns): (MQTTTopic.deviceStatus, ns.stamped(deviceName: deviceName).jsonString())
        case .client(let ns, _):
            config.streamStationRecords ? (MQTTTopic.wifiStation, ns.stamped(deviceName: deviceName).jsonString()) : nil
        case .rawFrame: nil
        }
    }

    private func wake() {
        waiter?.resume()
        waiter = nil
    }

    private func run() async {
        var backoff = Duration.seconds(1)
        while !Task.isCancelled {
            if !connected {
                do {
                    try await connect()
                    backoff = .seconds(1)
                } catch {
                    lastError = "Could not connect to \(config.host):\(config.port): \(error)"
                    if stopping { return }
                    try? await Task.sleep(for: backoff)
                    backoff = min(backoff * 2, maxBackoff)
                    continue
                }
            }
            if queue.isEmpty {
                if stopping { return }
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        if Task.isCancelled { continuation.resume() } else { waiter = continuation }
                    }
                } onCancel: {
                    Task { await self.wake() }
                }
                continue
            }
            await publish(queue.take(Self.batchSize))
        }
    }

    private func connect() async throws {
        guard let client else { throw CancellationError() }
        if client.isActive() { try? await client.disconnect() }
        // A persistent session, as the Android app uses, so the broker keeps
        // QoS 1 and 2 state across reconnects.
        try await client.connect(cleanSession: false)
        client.addCloseListener(named: "destination") { [weak self] _ in
            Task { await self?.connectionClosed() }
        }
        connected = true
        connectedOnce = true
        lastError = nil
    }

    private func connectionClosed() {
        connected = false
        wake()
    }

    private func publish(_ batch: [Message]) async {
        guard let client else { return queue.requeue(batch) }
        let qos = MQTTQoS(rawValue: config.qos) ?? .atLeastOnce
        let failed = await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, message) in batch.enumerated() {
                group.addTask {
                    do {
                        try await client.publish(to: message.topic, payload: message.payload, qos: qos)
                        return (index, true)
                    } catch {
                        return (index, false)
                    }
                }
            }
            var failed: [Int] = []
            for await (index, ok) in group where !ok { failed.append(index) }
            return failed.sorted()
        }
        let succeeded = batch.count - failed.count
        queue.finished(succeeded)
        published += succeeded
        if succeeded > 0 { lastSuccessAt = Date() }
        if !failed.isEmpty {
            queue.requeue(failed.map { batch[$0] })
            connected = client.isActive()
            if connected {
                try? await Task.sleep(for: .seconds(1))
            } else {
                lastError = "The connection to the MQTT broker was lost"
            }
        }
    }
}
