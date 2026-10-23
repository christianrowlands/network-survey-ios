import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices
import NSMessaging
import Testing
@testable import Destinations

/// What the test server received.
final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var _beacons: [ProtoWifiBeaconRecord] = []
    private var _probes: [ProtoWifiProbeRequestRecord] = []
    private var _bluetooth: [ProtoBluetoothRecord] = []
    private var _statuses: [ProtoDeviceStatus] = []
    private var _handshakes = 0

    var beacons: [ProtoWifiBeaconRecord] { lock.withLock { _beacons } }
    var probes: [ProtoWifiProbeRequestRecord] { lock.withLock { _probes } }
    var bluetooth: [ProtoBluetoothRecord] { lock.withLock { _bluetooth } }
    var statuses: [ProtoDeviceStatus] { lock.withLock { _statuses } }
    var handshakes: Int { lock.withLock { _handshakes } }
    var total: Int { lock.withLock { _beacons.count + _probes.count + _bluetooth.count + _statuses.count } }

    func add(_ body: (Received) -> Void) { lock.withLock { body(self) } }
    func handshake() { lock.withLock { _handshakes += 1 } }
    func append(beacon: ProtoWifiBeaconRecord) { _beacons.append(beacon) }
    func append(probe: ProtoWifiProbeRequestRecord) { _probes.append(probe) }
    func append(bluetooth: ProtoBluetoothRecord) { _bluetooth.append(bluetooth) }
    func append(status: ProtoDeviceStatus) { _statuses.append(status) }
}

struct HandshakeService: ConnectionHandshakeService.SimpleServiceProtocol {
    let received: Received
    let accept: Bool

    func startConnection(
        request: Com_Craxiom_Messaging_Grpc_ConnectionRequest, context: ServerContext
    ) async throws -> Com_Craxiom_Messaging_Grpc_ConnectionReply {
        received.handshake()
        return .with { $0.connectionAccept = accept }
    }
}

struct StatusService: DeviceStatusService.SimpleServiceProtocol {
    let received: Received

    func statusUpdate(
        request: RPCAsyncSequence<ProtoDeviceStatus, any Error>, context: ServerContext
    ) async throws -> Com_Craxiom_Messaging_Grpc_StatusUpdateReply {
        for try await message in request { received.add { $0.append(status: message) } }
        return .init()
    }
}

struct SurveyService: WirelessSurveyService.SimpleServiceProtocol {
    let received: Received
    let probesImplemented: Bool

    func streamWifiBeaconSurvey(
        request: RPCAsyncSequence<ProtoWifiBeaconRecord, any Error>, context: ServerContext
    ) async throws -> Com_Craxiom_Messaging_Grpc_WifiBeaconSurveyResponse {
        for try await message in request { received.add { $0.append(beacon: message) } }
        return .init()
    }

    func streamWifiProbeRequestSurvey(
        request: RPCAsyncSequence<ProtoWifiProbeRequestRecord, any Error>, context: ServerContext
    ) async throws -> Com_Craxiom_Messaging_Grpc_WifiProbeRequestSurveyResponse {
        guard probesImplemented else { throw RPCError(code: .unimplemented, message: "no probes here") }
        for try await message in request { received.add { $0.append(probe: message) } }
        return .init()
    }

    func streamBluetoothSurvey(
        request: RPCAsyncSequence<ProtoBluetoothRecord, any Error>, context: ServerContext
    ) async throws -> Com_Craxiom_Messaging_Grpc_BluetoothSurveyResponse {
        for try await message in request { received.add { $0.append(bluetooth: message) } }
        return .init()
    }

    private func unimplemented<T>() throws -> T { throw RPCError(code: .unimplemented, message: "test server") }

    func streamGsmSurvey(request: RPCAsyncSequence<Com_Craxiom_Messaging_GsmRecord, any Error>, context: ServerContext) async throws -> Com_Craxiom_Messaging_Grpc_GsmSurveyResponse { try unimplemented() }
    func streamCdmaSurvey(request: RPCAsyncSequence<Com_Craxiom_Messaging_CdmaRecord, any Error>, context: ServerContext) async throws -> Com_Craxiom_Messaging_Grpc_CdmaSurveyResponse { try unimplemented() }
    func streamUmtsSurvey(request: RPCAsyncSequence<Com_Craxiom_Messaging_UmtsRecord, any Error>, context: ServerContext) async throws -> Com_Craxiom_Messaging_Grpc_UmtsSurveyResponse { try unimplemented() }
    func streamLteSurvey(request: RPCAsyncSequence<Com_Craxiom_Messaging_LteRecord, any Error>, context: ServerContext) async throws -> Com_Craxiom_Messaging_Grpc_LteSurveyResponse { try unimplemented() }
    func streamNrSurvey(request: RPCAsyncSequence<Com_Craxiom_Messaging_NrRecord, any Error>, context: ServerContext) async throws -> Com_Craxiom_Messaging_Grpc_NrSurveyResponse { try unimplemented() }
    func streamPhoneState(request: RPCAsyncSequence<Com_Craxiom_Messaging_PhoneState, any Error>, context: ServerContext) async throws -> Com_Craxiom_Messaging_Grpc_PhoneStateResponse { try unimplemented() }
    func streamWifiOtaSurvey(request: RPCAsyncSequence<Com_Craxiom_Messaging_WifiOtaRecord, any Error>, context: ServerContext) async throws -> Com_Craxiom_Messaging_Grpc_WifiOtaSurveyResponse { try unimplemented() }
    func streamGnssSurvey(request: RPCAsyncSequence<Com_Craxiom_Messaging_GnssRecord, any Error>, context: ServerContext) async throws -> Com_Craxiom_Messaging_Grpc_GnssSurveyResponse { try unimplemented() }
    func streamEnergyDetections(request: RPCAsyncSequence<Com_Craxiom_Messaging_EnergyDetection, any Error>, context: ServerContext) async throws -> Com_Craxiom_Messaging_Grpc_EnergyDetectionResponse { try unimplemented() }
    func streamSignalDetections(request: RPCAsyncSequence<Com_Craxiom_Messaging_SignalDetection, any Error>, context: ServerContext) async throws -> Com_Craxiom_Messaging_Grpc_SignalDetectionResponse { try unimplemented() }
    func streamLteRrc(request: RPCAsyncSequence<Com_Craxiom_Messaging_LteRrc, any Error>, context: ServerContext) async throws -> Com_Craxiom_Messaging_Grpc_LteRrcResponse { try unimplemented() }
    func streamLteNas(request: RPCAsyncSequence<Com_Craxiom_Messaging_LteNas, any Error>, context: ServerContext) async throws -> Com_Craxiom_Messaging_Grpc_LteNasResponse { try unimplemented() }
}

/// A tiny in-process NS Messaging gRPC server on a free local port.
final class TestServer: @unchecked Sendable {
    let received = Received()
    let port: Int
    private let server: GRPCServer<HTTP2ServerTransport.TransportServices>
    private let task: Task<Void, Error>

    init(accept: Bool = true, probesImplemented: Bool = true) async throws {
        let transport = HTTP2ServerTransport.TransportServices(
            address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: .plaintext
        )
        let services: [any RegistrableRPCService] = [
            HandshakeService(received: received, accept: accept),
            StatusService(received: received),
            SurveyService(received: received, probesImplemented: probesImplemented),
        ]
        let server = GRPCServer(transport: transport, services: services)
        self.server = server
        task = Task { try await server.serve() }
        port = try await transport.listeningAddress.ipv4!.port
    }

    func stop() async {
        server.beginGracefulShutdown()
        _ = try? await task.value
    }

    func waitFor(_ count: Int, timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now + timeout
        while received.total < count && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
    }
}

@Suite("gRPC destination", .serialized)
struct GRPCTests {
    @Test("Handshakes, then streams each record type with the device name stamped")
    func streams() async throws {
        let server = try await TestServer()
        let destination = GRPCDestination(config: GRPCConfig(host: "127.0.0.1", port: server.port))
        try await destination.start(Samples.session(Samples.tempDirectory()))
        await destination.accept([Samples.apRecord(1), Samples.apRecord(2), Samples.probeRecord(), Samples.bleRecord(),
                                  Samples.statusRecord(), Samples.clientRecord()])
        try await server.waitFor(5)
        await destination.stop()
        await server.stop()

        #expect(server.received.handshakes == 1)
        #expect(server.received.beacons.map(\.data.recordNumber) == [1, 2])
        #expect(server.received.probes.count == 1)
        #expect(server.received.bluetooth.count == 1)
        #expect(server.received.statuses.count == 1)
        let beacon = try #require(server.received.beacons.first)
        #expect(beacon.data.deviceName == "Field kit 2")
        #expect(beacon.data.bssid == "02:00:5e:00:53:01")
        #expect(beacon.data.encryptionType == .wpa2Wpa3)
        #expect(beacon.data.signalStrength.value == -48)
        #expect(beacon.data.beaconInterval.value == 100)
        #expect(beacon.data.akmSuites == [.psk, .sae])
        #expect(server.received.statuses.first?.data.batteryLevelPercent.value == 80)
        #expect(await destination.sentCount == 5)
    }

    @Test("An unimplemented method is dropped; the other streams keep going")
    func unimplemented() async throws {
        let server = try await TestServer(probesImplemented: false)
        let destination = GRPCDestination(config: GRPCConfig(host: "127.0.0.1", port: server.port, reconnectDelay: .milliseconds(200)))
        try await destination.start(Samples.session(Samples.tempDirectory()))
        await destination.accept([Samples.probeRecord()])
        try await Task.sleep(for: .milliseconds(500))
        await destination.accept([Samples.probeRecord(2), Samples.apRecord()])
        try await server.waitFor(1)
        try await Task.sleep(for: .milliseconds(300))
        let snapshot = await destination.snapshot()
        await destination.stop()
        await server.stop()
        #expect(server.received.beacons.count == 1)
        #expect(server.received.probes.isEmpty)
        #expect(server.received.handshakes == 1) // no reconnect
        #expect(snapshot.status == .running)
        #expect(snapshot.queueDepth == 0)
    }

    @Test("A refused handshake reports an error and retries")
    func refused() async throws {
        let server = try await TestServer(accept: false)
        let destination = GRPCDestination(config: GRPCConfig(host: "127.0.0.1", port: server.port, reconnectDelay: .milliseconds(200)))
        try await destination.start(Samples.session(Samples.tempDirectory()))
        await destination.accept([Samples.apRecord()])
        try await Task.sleep(for: .seconds(1))
        let snapshot = await destination.snapshot()
        await destination.stop()
        await server.stop()
        #expect(server.received.handshakes >= 2)
        #expect(server.received.beacons.isEmpty)
        #expect(snapshot.queueDepth == 1)
        if case .error = snapshot.status {} else { Issue.record("expected an error status, got \(snapshot.status)") }
    }

    #if os(macOS)
    @Test("Stop does not wait out the reconnect delay when no server answers")
    func fastStop() async throws {
        let destination = GRPCDestination(config: GRPCConfig(host: "127.0.0.1", port: try LocalBroker.freePort()))
        try await destination.start(Samples.session(Samples.tempDirectory()))
        await destination.accept([Samples.apRecord()])
        try await Task.sleep(for: .milliseconds(500))
        let started = ContinuousClock.now
        await destination.stop()
        #expect(ContinuousClock.now - started < .seconds(2))
    }
    #endif

    @Test("Messages convert from NS JSON to protobuf without losing fields")
    func conversion() throws {
        let record = Samples.bleRecord()
        guard case .bluetooth(let message)? = try GRPCOutgoing(record, deviceName: "kit") else {
            Issue.record("not converted")
            return
        }
        #expect(message.data.companyID == "4c")
        #expect(message.data.technology == .le)
        #expect(message.data.addressType == .random)
        #expect(message.data.deviceName == "kit")
        #expect(try GRPCOutgoing(Samples.clientRecord(), deviceName: "kit") == nil)
    }
}
