import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices
import GRPCProtobuf

public struct GRPCConfig: Sendable, Equatable {
    public var host: String
    public var port: Int
    /// The Android app connects in plaintext; TLS uses the system trust store.
    public var useTLS: Bool
    /// Most records queued per record type; 0 means the default of 20,000
    /// (as in the Android app, gRPC queues are always bounded).
    public var queueLimit: Int
    /// Wait before reconnecting after a failure (10 s in the Android app).
    public var reconnectDelay: Duration
    /// Limit for the ConnectionHandshake call.
    public var handshakeTimeout: Duration

    public init(
        host: String, port: Int, useTLS: Bool = false, queueLimit: Int = 0,
        reconnectDelay: Duration = .seconds(10), handshakeTimeout: Duration = .seconds(10)
    ) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.queueLimit = queueLimit
        self.reconnectDelay = reconnectDelay
        self.handshakeTimeout = handshakeTimeout
    }
}

/// Streams records to an NS Messaging gRPC server like the Android app: a
/// ConnectionHandshake first, then one client stream per record type
/// (WirelessSurvey beacon, probe request and Bluetooth streams, DeviceStatus
/// StatusUpdate). A method the server does not implement is dropped quietly;
/// any other failure reconnects everything after `reconnectDelay`.
public actor GRPCDestination: Destination {
    public nonisolated let kind = DestinationKind.grpc

    static let defaultQueueLimit = 20_000
    private typealias Transport = HTTP2ClientTransport.TransportServices

    private let config: GRPCConfig
    private var session: SessionInfo?
    private var deviceName = ""
    private var queues: [GRPCStream: StreamQueue<GRPCOutgoing>] = [:]
    private var waiters: [GRPCStream: CheckedContinuation<Void, Never>] = [:]
    private var unimplemented: Set<GRPCStream> = []
    private var runner: Task<Void, Never>?
    private var connected = false
    private var stopping = false
    private var recordsAccepted = 0
    private var sent = 0
    private var lastError: String?
    private var lastSuccessAt: Date?

    public init(config: GRPCConfig) {
        self.config = config
    }

    public func start(_ session: SessionInfo) async throws {
        guard !config.host.isEmpty, (1...65535).contains(config.port) else {
            throw DestinationError.invalidSettings("The gRPC server host or port is not valid")
        }
        self.session = session
        // Like the Android app's gRPC service: an empty name leaves records
        // unchanged (MQTT falls back to its client ID instead, as on Android).
        deviceName = session.deviceName
        let limit = config.queueLimit > 0 ? config.queueLimit : Self.defaultQueueLimit
        queues = Dictionary(uniqueKeysWithValues: GRPCStream.allCases.map { ($0, StreamQueue(limit: limit)) })
        unimplemented = []
        stopping = false
        runner = Task { await self.run() }
    }

    public func accept(_ records: [SurveyRecord]) async {
        guard session != nil, !stopping else { return }
        for record in records {
            do {
                guard let message = try GRPCOutgoing(record, deviceName: deviceName),
                      !unimplemented.contains(message.stream) else { continue }
                if queues[message.stream]?.append(message) == true { recordsAccepted += 1 }
                wake(message.stream)
            } catch {
                lastError = "Could not convert a record for gRPC: \(error)"
            }
        }
    }

    public func stop() async {
        guard let runner else { return }
        stopping = true
        for stream in GRPCStream.allCases { wake(stream) }
        // Connected: give the open streams a moment to send what is queued.
        // Otherwise there is nothing to wait for (a reconnect delay or a
        // handshake), and both end on cancellation.
        if !connected { runner.cancel() }
        let timeout = Task { try? await Task.sleep(for: .seconds(5)); runner.cancel() }
        await runner.value
        timeout.cancel()
        self.runner = nil
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
        snapshot.queueDepth = queues.values.reduce(0) { $0 + $1.depth }
        snapshot.droppedRecords = queues.values.reduce(0) { $0 + $1.dropped }
        snapshot.lastError = lastError
        snapshot.lastSuccessAt = lastSuccessAt
        return snapshot
    }

    /// Messages written to the server so far (for tests and diagnostics).
    public var sentCount: Int { sent }

    private func run() async {
        while !Task.isCancelled {
            await connectAndStream()
            connected = false
            if stopping || Task.isCancelled { return }
            if unimplemented.count == GRPCStream.allCases.count {
                lastError = "The gRPC server implements none of the survey streams"
                return
            }
            try? await Task.sleep(for: config.reconnectDelay)
        }
    }

    private func connectAndStream() async {
        do {
            let transport = try Transport(
                target: .dns(host: config.host, port: config.port),
                transportSecurity: config.useTLS ? .tls : .plaintext
            )
            let client = GRPCClient(transport: transport)
            try await withThrowingDiscardingTaskGroup { group in
                group.addTask { try await client.runConnections() }
                defer { client.beginGracefulShutdown() }
                var options = CallOptions.defaults
                options.timeout = config.handshakeTimeout
                let accepted = try await ConnectionHandshakeService.Client(wrapping: client).startConnection(
                    Com_Craxiom_Messaging_Grpc_ConnectionRequest(), options: options
                ) { try $0.message.connectionAccept }
                guard accepted else { throw RPCError(code: .permissionDenied, message: "The server refused the connection") }
                connected = true
                lastError = nil
                try await withThrowingTaskGroup(of: Void.self) { streams in
                    for stream in GRPCStream.allCases where !unimplemented.contains(stream) {
                        streams.addTask { try await self.runStream(stream, client: client) }
                    }
                    try await streams.waitForAll()
                }
            }
        } catch {
            if !stopping { lastError = "gRPC connection to \(config.host):\(config.port) failed: \(error)" }
        }
    }

    /// Runs one client stream until the destination stops. Returns normally if
    /// the server does not implement the method, so the others keep going.
    private nonisolated func runStream(_ stream: GRPCStream, client: GRPCClient<Transport>) async throws {
        do {
            switch stream {
            case .wifiBeacon:
                _ = try await WirelessSurveyService.Client(wrapping: client).streamWifiBeaconSurvey { writer in
                    try await self.produce(.wifiBeacon, into: writer, \.wifiBeacon)
                }
            case .wifiProbeRequest:
                _ = try await WirelessSurveyService.Client(wrapping: client).streamWifiProbeRequestSurvey { writer in
                    try await self.produce(.wifiProbeRequest, into: writer, \.wifiProbeRequest)
                }
            case .bluetooth:
                _ = try await WirelessSurveyService.Client(wrapping: client).streamBluetoothSurvey { writer in
                    try await self.produce(.bluetooth, into: writer, \.bluetooth)
                }
            case .deviceStatus:
                _ = try await DeviceStatusService.Client(wrapping: client).statusUpdate { writer in
                    try await self.produce(.deviceStatus, into: writer, \.deviceStatus)
                }
            }
        } catch let error as RPCError where error.code == .unimplemented {
            await markUnimplemented(stream)
            return
        }
        // A stream the server ended while the survey runs: reconnect, as the Android app does.
        if await !isStopping {
            throw RPCError(code: .unavailable, message: "The server ended the stream")
        }
    }

    private var isStopping: Bool { stopping }

    private nonisolated func produce<M: Sendable>(
        _ stream: GRPCStream, into writer: RPCWriter<M>, _ extract: @Sendable (GRPCOutgoing) -> M?
    ) async throws {
        while let batch = await next(stream) {
            do {
                try await writer.write(contentsOf: batch.compactMap(extract))
                await delivered(stream, batch.count)
            } catch {
                // Records written into a failed stream are lost, as in the Android app.
                await delivered(stream, 0, lost: batch.count)
                throw error
            }
        }
    }

    /// The next records for a stream, waiting while there are none. Nil once
    /// the destination is stopping and the queue is empty.
    private func next(_ stream: GRPCStream) async -> [GRPCOutgoing]? {
        while queues[stream]?.isEmpty ?? true {
            if stopping || Task.isCancelled { return nil }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled { continuation.resume() } else { waiters[stream] = continuation }
                }
            } onCancel: {
                Task { await self.wake(stream) }
            }
        }
        return queues[stream]?.take(64)
    }

    private func delivered(_ stream: GRPCStream, _ count: Int, lost: Int = 0) {
        queues[stream]?.finished(count + lost)
        sent += count
        if count > 0 { lastSuccessAt = Date() }
    }

    private func markUnimplemented(_ stream: GRPCStream) {
        unimplemented.insert(stream)
        queues[stream]?.removeAll()
    }

    private func wake(_ stream: GRPCStream) {
        waiters.removeValue(forKey: stream)?.resume()
    }
}
