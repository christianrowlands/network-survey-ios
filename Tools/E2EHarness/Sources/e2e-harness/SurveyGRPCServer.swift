import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices

/// The NS Messaging gRPC server the Android app streams to, reduced to what the
/// iOS app uses: ConnectionHandshake.StartConnection, the WirelessSurvey beacon,
/// probe request and Bluetooth streams, and DeviceStatus.StatusUpdate. Messages
/// stay as bytes; only the shared data fields are read (`ProtoWire`), so the
/// harness needs no generated code.
struct SurveyGRPCService: RegistrableRPCService {
    static let package = "com.craxiom.messaging.grpc"
    /// Method name and the data field numbers of missionId, recordNumber and the
    /// address (bssid for beacons, sourceAddress otherwise).
    static let streams: [(service: String, method: String, fields: ProtoWire.Layout)] = [
        ("WirelessSurvey", "StreamWifiBeaconSurvey", .init(mission: 7, number: 8, address: 12)),
        ("WirelessSurvey", "StreamWifiProbeRequestSurvey", .init(mission: 7, number: 8, address: 10)),
        ("WirelessSurvey", "StreamBluetoothSurvey", .init(mission: 7, number: 8, address: 10)),
        ("DeviceStatus", "StatusUpdate", .init(mission: 13, number: 14, address: nil)),
    ]

    let tally: Tally

    func registerMethods<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
        let tally = tally
        router.registerHandler(
            forMethod: MethodDescriptor(fullyQualifiedService: "\(Self.package).ConnectionHandshake", method: "StartConnection"),
            deserializer: RawBytes(), serializer: RawBytes()
        ) { request, _ in
            for try await _ in request.messages {}
            tally.update { $0.handshakes += 1 }
            // ConnectionReply { bool connectionAccept = 1; } with true.
            return StreamingServerResponse(single: ServerResponse(message: [0x08, 0x01]))
        }
        for stream in Self.streams {
            router.registerHandler(
                forMethod: MethodDescriptor(fullyQualifiedService: "\(Self.package).\(stream.service)", method: stream.method),
                deserializer: RawBytes(), serializer: RawBytes()
            ) { request, _ in
                for try await message in request.messages {
                    let fields = ProtoWire.record(message, layout: stream.fields)
                    tally.update { $0.grpc[stream.method, default: ChannelTally()].add(fields) }
                }
                // Every reply message of these methods is empty.
                return StreamingServerResponse(single: ServerResponse(message: []))
            }
        }
    }
}

/// Passes message bytes through unchanged.
struct RawBytes: MessageSerializer, MessageDeserializer {
    func serialize<Bytes: GRPCContiguousBytes>(_ message: [UInt8]) throws -> Bytes {
        Bytes(message)
    }

    func deserialize<Bytes: GRPCContiguousBytes>(_ serializedMessageBytes: Bytes) throws -> [UInt8] {
        serializedMessageBytes.withUnsafeBytes { Array($0) }
    }
}

/// Reads the common data fields of an NS Messaging record from protobuf bytes:
/// `data` is field 3 of every record; inside it deviceSerialNumber is 1,
/// deviceName 2, latitude 4 and longitude 5.
enum ProtoWire {
    struct Layout {
        var mission: Int
        var number: Int
        var address: Int?
    }

    static func record(_ bytes: [UInt8], layout: Layout) -> RecordFields {
        var fields = RecordFields()
        guard let data = Self.fields(bytes)[3]?.last?.bytes else { return fields }
        let inner = Self.fields(data)
        func string(_ number: Int) -> String {
            inner[number]?.last?.bytes.map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        func double(_ number: Int) -> Double {
            inner[number]?.last?.fixed64.map { Double(bitPattern: $0) } ?? 0
        }
        fields.serial = string(1)
        fields.deviceName = string(2)
        fields.missionId = string(layout.mission)
        fields.recordNumber = Int(Int32(truncatingIfNeeded: inner[layout.number]?.last?.varint ?? 0))
        fields.latitude = double(4)
        fields.longitude = double(5)
        fields.address = layout.address.map(string)
        return fields
    }

    struct Value {
        var varint: UInt64?
        var fixed64: UInt64?
        var bytes: [UInt8]?
    }

    /// Field number to values, for one message level.
    static func fields(_ bytes: [UInt8]) -> [Int: [Value]] {
        var result: [Int: [Value]] = [:]
        var index = 0
        func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count, shift < 64 {
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while index < bytes.count, let key = varint() {
            let number = Int(key >> 3)
            var value = Value()
            switch key & 7 {
            case 0:
                value.varint = varint()
            case 1:
                guard index + 8 <= bytes.count else { return result }
                value.fixed64 = bytes[index..<index + 8].reversed().reduce(0) { $0 << 8 | UInt64($1) }
                index += 8
            case 2:
                guard let length = varint(), index + Int(length) <= bytes.count else { return result }
                value.bytes = Array(bytes[index..<index + Int(length)])
                index += Int(length)
            case 5:
                index += 4
            default:
                return result
            }
            result[number, default: []].append(value)
        }
        return result
    }
}

/// Serves `SurveyGRPCService` on a free local port.
final class SurveyGRPCServer: Sendable {
    let port: Int
    private let server: GRPCServer<HTTP2ServerTransport.TransportServices>

    init(tally: Tally) async throws {
        let transport = HTTP2ServerTransport.TransportServices(
            address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: .plaintext
        )
        let server = GRPCServer(transport: transport, services: [SurveyGRPCService(tally: tally)])
        self.server = server
        Task {
            do { try await server.serve() } catch { FileHandle.standardError.write(Data("e2e-harness: gRPC server: \(error)\n".utf8)) }
        }
        guard let port = try await transport.listeningAddress.ipv4?.port else {
            throw HarnessError("The gRPC server has no IPv4 address")
        }
        self.port = port
    }

    func stop() {
        server.beginGracefulShutdown()
    }
}

struct HarnessError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
