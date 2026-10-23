import Foundation
import SwiftProtobuf
import Testing
@testable import BoardProtocol

/// Decodes the fixtures the firmware's nanopb host test writes (copied here by
/// scripts/sync-proto.sh) and checks every field, proving nanopb and SwiftProtobuf
/// agree on the wire format. Re-encoding must also give the same bytes.
@Suite struct FixtureTests {
    private static let t0: UInt64 = 1_767_225_600_123
    private static let apBssid = Data([0x02, 0x00, 0x5E, 0x10, 0x00, 0x01])
    private static let broadcast = Data(repeating: 0xFF, count: 6)

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "bin", subdirectory: "Fixtures"),
            "missing fixture \(name).bin (run scripts/sync-proto.sh)")
        return try Data(contentsOf: url)
    }

    private func decode<M: Message>(_ name: String, as type: M.Type) throws -> M {
        let bytes = try fixture(name)
        let message = try M(serializedBytes: bytes)
        #expect(message.unknownFields.data.isEmpty, "\(name) has fields this proto does not know")
        let reencoded: Data = try message.serializedData()
        #expect(reencoded == bytes, "\(name) re-encodes differently")
        return message
    }

    private func singleRecord(_ name: String) throws -> NSBRecord.OneOf_Kind? {
        let batch = try decode(name, as: NSBRecordBatch.self)
        #expect(batch.timeSynced)
        #expect(batch.records.count == 1)
        return batch.records.first?.kind
    }

    @Test func apObservation() throws {
        guard case .ap(let ap) = try singleRecord("record_ap") else {
            Issue.record("expected ap")
            return
        }
        #expect(ap.boardTimeMs == Self.t0)
        #expect(ap.channel == 6 && ap.frequencyMhz == 2437 && ap.band == .ghz24)
        #expect(ap.bssid == Self.apBssid)
        #expect(ap.ssid == Data("ExampleNet".utf8) && !ap.ssidHidden)
        #expect(ap.rssiMax == -42 && ap.rssiLast == -47)
        #expect(ap.hasNoiseFloorDbm && ap.noiseFloorDbm == -95)
        #expect(ap.beaconCount == 9 && ap.probeResponseCount == 2)
        #expect(ap.hasBeaconIntervalTu && ap.beaconIntervalTu == 100)
        #expect(ap.capabilityInfo == 0x0431)
        #expect(ap.security == .wpa2Wpa3)
        #expect(ap.groupCipher == 0x000F_AC04)
        #expect(ap.pairwiseCiphers == [0x000F_AC04])
        #expect(ap.akmSuites == [0x000F_AC02, 0x000F_AC08])
        #expect(ap.phyFlags == UInt32(NSBPhyFlag.ht.rawValue | NSBPhyFlag.vht.rawValue | NSBPhyFlag.he.rawValue))
        #expect(ap.channelWidth == .mhz40)
        #expect(ap.wps && !ap.passpoint)
        #expect(ap.supportedRates == Data([0x82, 0x84, 0x8B, 0x96, 0x0C, 0x12, 0x18, 0x24]))
        #expect(ap.extendedSupportedRates == Data([0x30, 0x48, 0x60, 0x6C]))
        #expect(ap.hasStationCount && ap.stationCount == 5)
        #expect(ap.hasChannelUtilization && ap.channelUtilization == 37)
    }

    @Test func clientObservation() throws {
        guard case .client(let client) = try singleRecord("record_client") else {
            Issue.record("expected client")
            return
        }
        #expect(client.boardTimeMs == Self.t0 + 500)
        #expect(client.channel == 36 && client.frequencyMhz == 5180 && client.band == .ghz5)
        #expect(client.clientMac == Data([0x0A, 0x11, 0x22, 0x33, 0x44, 0x55]))
        #expect(client.associatedBssid == Self.apBssid)
        #expect(client.rssiMax == -60 && client.rssiLast == -63)
        #expect(!client.hasNoiseFloorDbm)
        #expect(client.frameCount == 14)
        let flags = NSBClientSource.data.rawValue | NSBClientSource.nullData.rawValue
            | NSBClientSource.action.rawValue
        #expect(client.sourceFlags == UInt32(flags))
        #expect(client.locallyAdministered)
    }

    @Test func probeObservation() throws {
        guard case .probe(let probe) = try singleRecord("record_probe") else {
            Issue.record("expected probe")
            return
        }
        #expect(probe.boardTimeMs == Self.t0 + 750)
        #expect(probe.channel == 1 && probe.frequencyMhz == 2412 && probe.band == .ghz24)
        #expect(probe.clientMac == Data([0x0A, 0x66, 0x77, 0x88, 0x99, 0xAA]))
        #expect(probe.ssid == Data("Cafe-Guest".utf8))
        #expect(probe.rssiMax == -71 && probe.rssiLast == -75)
        #expect(probe.count == 3 && probe.locallyAdministered)
        #expect(probe.destinationAddress == Self.broadcast && probe.bssid == Self.broadcast)
        #expect(probe.phyFlags == UInt32(NSBPhyFlag.ht.rawValue))
    }

    @Test func bleObservation() throws {
        guard case .ble(let ble) = try singleRecord("record_ble") else {
            Issue.record("expected ble")
            return
        }
        #expect(ble.boardTimeMs == Self.t0 + 2000)
        #expect(ble.channel == 37)
        #expect(ble.address == Data([0xC2, 0x00, 0x5E, 0x00, 0x00, 0x01]))
        #expect(ble.addressType == .random)
        #expect(ble.rssiMax == -80 && ble.rssiLast == -82 && ble.count == 11)
        #expect(ble.advType == .advInd && !ble.advDataTruncated)
        #expect(ble.advData.count == 24 && ble.advData.prefix(3) == Data([0x02, 0x01, 0x06]))
        #expect(ble.localName == Data("ExampleTag".utf8) && ble.localNameText == "ExampleTag")
        #expect(ble.hasCompanyID && ble.companyID == 0xFFFF)
        #expect(ble.hasTxPower && ble.txPower == -12)
    }

    @Test func gpsFix() throws {
        guard case .gps(let gps) = try singleRecord("record_gps") else {
            Issue.record("expected gps")
            return
        }
        #expect(gps.boardTimeMs == Self.t0 + 3000)
        #expect(gps.latitude == 39.7392 && gps.longitude == -104.9903)
        #expect(gps.hasAltitudeM && gps.altitudeM == 1609.5)
        #expect(gps.hasHdop && gps.hdop == Float(0.9))
        #expect(gps.satellites == 9)
        #expect(gps.fixTimeMs == Self.t0 + 2877)
        #expect(gps.fixQuality == 1)
        #expect(gps.speedMps == 12.5 && gps.courseDeg == 270)
    }

    @Test func mixedBatchBeforeTimeSync() throws {
        let batch = try decode("record_batch_mixed", as: NSBRecordBatch.self)
        #expect(!batch.timeSynced)
        #expect(batch.records.count == 3)
        guard batch.records.count == 3,
              case .ap(let ap) = batch.records[0].kind,
              case .ble(let ble) = batch.records[1].kind,
              case .gps(let gps) = batch.records[2].kind else {
            Issue.record("unexpected record kinds")
            return
        }
        #expect(ap.boardTimeMs == 15000 && ap.ssid == Data("ExampleNet".utf8))
        #expect(ble.boardTimeMs == 15250 && ble.localName == Data("ExampleTag".utf8))
        #expect(gps.boardTimeMs == 15500)
    }

    @Test func boardInfo() throws {
        let info = try decode("board_info", as: NSBBoardInfo.self)
        #expect(info.protocolMajor == UInt32(NSBProtocolVersion.major.rawValue))
        #expect(info.protocolMinor == UInt32(NSBProtocolVersion.minor.rawValue))
        #expect(info.firmwareVersion == "0.1.0")
        #expect(info.boardModel == .esp32C5Devkitc1 && info.chip == .esp32C5)
        #expect(info.bands == [.ghz24, .ghz5])
        #expect(!info.gpsPresent)
        #expect(info.shortID == "ABCD" && info.preferredMtu == 517)
        #expect(info.btAddress == Data([0x02, 0x00, 0x5E, 0x00, 0xAB, 0xCD]))
        #expect(info.modelName == "ESP32-C5-DevKitC-1")
    }

    @Test func boardStatus() throws {
        let status = try decode("board_status", as: NSBBoardStatus.self)
        #expect(status.boardTimeMs == Self.t0 + 10000 && status.timeSynced)
        #expect(status.state == .surveying && status.role == .band5)
        #expect(status.currentChannel == 149)
        #expect(status.recordsPerSec == 42 && status.ringFillPercent == 12)
        #expect(status.droppedRecords == 3 && status.droppedRawFrames == 0 && status.droppedRxFrames == 17)
        #expect(status.rxFramesPerSec == 850 && status.uptimeMs == 3_600_000)
        #expect(status.freeHeapBytes == 180_000 && status.minFreeHeapBytes == 150_000)
        #expect(status.gpsState == .notPresent)
        #expect(status.hasBatteryMv && status.batteryMv == 3900)
        #expect(!status.pairingMode && status.bondCount == 1 && status.mtu == 247)
    }

    @Test func controlRequestConfigure() throws {
        let request = try decode("control_request_configure", as: NSBControlRequest.self)
        #expect(request.requestID == 7)
        guard case .configure(let config) = request.command else {
            Issue.record("expected configure")
            return
        }
        #expect(config.wifiAp && config.wifiClient && config.wifiProbes && !config.ble && config.rawFrames)
        #expect(config.role == .auto)
        #expect(config.channels == [1, 6, 11, 36, 40, 44, 48, 149])
        #expect(config.dwell24Ms == 250 && config.dwell5Ms == 150)
        #expect(config.rawSnaplen == 128 && config.rawMaxFramesPerSec == 50 && config.rawTypeMask == 1)
    }

    @Test func controlRequestHello() throws {
        let request = try decode("control_request_hello", as: NSBControlRequest.self)
        #expect(request.requestID == 1)
        #expect(request.command == .hello(.with { $0.protocolMajor = 1; $0.appVersion = "1.0.0" }))
    }

    @Test func controlResponseHello() throws {
        let response = try decode("control_response_hello", as: NSBControlResponse.self)
        #expect(response.requestID == 1 && response.result == .ok && response.message.isEmpty)
        guard case .hello(let hello) = response.payload else {
            Issue.record("expected hello result")
            return
        }
        #expect(hello.protocolMajor == 1 && hello.protocolMinor == 0)
        #expect(hello.compatible && hello.firmwareVersion == "0.1.0" && hello.otaImageConfirmed)
    }

    @Test func rawFrame() throws {
        let frame = try decode("raw_frame", as: NSBRawFrame.self)
        #expect(frame.boardTimeUs == Self.t0 * 1000 + 456 && frame.timeSynced)
        #expect(frame.channel == 6 && frame.frequencyMhz == 2437 && frame.band == .ghz24)
        #expect(frame.rssi == -44 && frame.hasNoiseFloorDbm && frame.noiseFloorDbm == -96)
        #expect(frame.phy == .legacy && frame.rate500Kbps == 2 && !frame.hasMcs)
        #expect(frame.origLen == 180 && !frame.fcsIncluded)
        #expect(frame.data.count == 40)
        #expect(frame.data.prefix(4) == Data([0x80, 0x00, 0x00, 0x00]))
        #expect(frame.data.suffix(4) == Data([0x00, 0x0A, 0x45, 0x78]))
    }

    @Test func otaAck() throws {
        let ack = try decode("ota_ack", as: NSBOtaAck.self)
        #expect(ack.nextOffset == 65536 && ack.status == .ok)
    }
}
