import BoardProtocol
import Foundation
import Testing
@testable import BoardKit

/// Notification bytes produced by the firmware's C framing code
/// (`test/fixtures/framing` in the firmware repo, copied by scripts/sync-proto.sh),
/// decoded by the phone-side decoder: the only cross-implementation framing check.
@Suite("Firmware framing fixtures")
struct FramingFixtureTests {
    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "bin", subdirectory: "Fixtures/framing"))
        return try Data(contentsOf: url)
    }

    @Test("Control indication: the protocol.md Ping response")
    func controlPing() throws {
        var decoder = BoardNotificationDecoder()
        let data = try Self.fixture("control_ping_response_seq0")
        #expect(data.count == 20)
        let responses = try decoder.decodeControl(data)
        #expect(decoder.control.lastSequence == 0)
        let response = try #require(responses.first)
        #expect(responses.count == 1 && response.requestID == 5 && response.result == .ok)
        guard case .ping(let ping)? = response.payload else {
            Issue.record("no PingResult")
            return
        }
        #expect(ping.nonce == 1 && ping.boardTimeMs == 1_767_225_600_123 && ping.timeSynced)
    }

    @Test("OTA ack: the protocol.md example")
    func otaAck() throws {
        var decoder = BoardNotificationDecoder()
        let acks = try decoder.decodeOtaAcks(Self.fixture("ota_ack_seq258"))
        #expect(decoder.ota.lastSequence == 258)
        #expect(acks.count == 1 && acks[0].nextOffset == 4096 && acks[0].status == .ok)
    }

    @Test("Status: two messages in one frame")
    func statusTwo() throws {
        var decoder = BoardNotificationDecoder()
        let data = try Self.fixture("status_two_messages_seq7")
        #expect(data.count == 106)
        let statuses = try decoder.decodeStatus(data)
        #expect(decoder.status.lastSequence == 7)
        #expect(statuses.count == 2 && statuses[0] == statuses[1])
    }

    @Test("Records at MTU 185: three consecutive frames across the sequence wrap, no gap")
    func recordsMTU185() throws {
        var decoder = BoardNotificationDecoder()
        var kinds: [[BoardRecordKind]] = []
        var sequences: [UInt16] = []
        for index in 0..<3 {
            let data = try Self.fixture("records_mtu185_frame\(index)")
            #expect(data.count <= 185 - 3)
            let batches = try decoder.decodeRecords(data, receivedAt: Date())
            #expect(batches.count == 1)
            let batch = try #require(batches.first)
            #expect(batch.missedNotifications == 0)
            #expect(batch.batch.timeSynced)
            sequences.append(batch.sequence)
            kinds.append(batch.batch.records.compactMap(\.recordKind))
        }
        #expect(sequences == [65535, 0, 1])
        #expect(kinds == [[.ap, .client], [.probe, .ble], [.gps]])
        #expect(decoder.records.missedTotal == 0)
    }

    @Test("Records at MTU 517: five records, two-byte batch length, not synced")
    func recordsMTU517() throws {
        var decoder = BoardNotificationDecoder()
        let data = try Self.fixture("records_mtu517_seq9")
        #expect(data.count == 360)
        let batch = try #require(decoder.decodeRecords(data, receivedAt: Date()).first)
        #expect(batch.sequence == 9 && !batch.batch.timeSynced)
        #expect(batch.batch.records.compactMap(\.recordKind) == [.ap, .client, .probe, .ble, .gps])
    }

    @Test("Exact fit: one 173-byte AP record fills an MTU 185 notification")
    func exactFit() throws {
        var decoder = BoardNotificationDecoder()
        let data = try Self.fixture("records_exact_fit_mtu185_seq42")
        #expect(data.count == 185 - 3)
        let batch = try #require(decoder.decodeRecords(data, receivedAt: Date()).first)
        #expect(batch.sequence == 42 && batch.batch.timeSynced)
        let record = try #require(batch.batch.records.first)
        #expect(batch.batch.records.count == 1 && record.recordKind == .ap)
        #expect(try record.serializedData().count == 173)
    }
}
