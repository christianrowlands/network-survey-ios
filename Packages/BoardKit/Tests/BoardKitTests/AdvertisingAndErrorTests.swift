import BoardProtocol
import Foundation
import Testing
@testable import BoardKit

@Suite("Advertising data and BLE errors")
struct AdvertisingAndErrorTests {
    @Test("Manufacturer data parses every flag and the model")
    func parseFlags() throws {
        // Company 0xFFFF little-endian, major 1, flags pairable + GPS, model XIAO C5.
        let parsed = try #require(BoardAdvertisement.parse(manufacturerData: Data([0xFF, 0xFF, 0x01, 0x05, 0x03])))
        #expect(parsed == BoardAdvertisement(
            companyID: 0xFFFF, protocolMajor: 1, pairable: true, hasBond: false, hasGPS: true, supports5GHz: false, model: .xiaoEsp32C5
        ))
        let bonded = try #require(BoardAdvertisement.parse(manufacturerData: Data([0x34, 0x12, 0x02, 0x0A, 0x04])))
        #expect(bonded.companyID == 0x1234)
        #expect(bonded.protocolMajor == 2)
        #expect(!bonded.pairable && bonded.hasBond && !bonded.hasGPS && bonded.supports5GHz)
        #expect(bonded.model == .esp32C6Generic)
    }

    @Test("Reserved flag bits are ignored, extra bytes too, short payloads are rejected")
    func parseEdges() {
        #expect(BoardAdvertisement.parse(manufacturerData: Data([0xFF, 0xFF, 0x01, 0xF0, 0x02, 0x99]))?.pairable == false)
        #expect(BoardAdvertisement.parse(manufacturerData: Data([0xFF, 0xFF, 0x01, 0x00])) == nil)
        #expect(BoardAdvertisement.parse(manufacturerData: Data()) == nil)
        // An unknown model number from a newer board is kept, not lost.
        #expect(BoardAdvertisement.parse(manufacturerData: Data([0xFF, 0xFF, 0x01, 0x00, 0xEE]))?.model == .UNRECOGNIZED(0xEE))
    }

    @Test("Encoding round-trips", arguments: 0..<16)
    func roundTrip(flags: Int) throws {
        let advertisement = BoardAdvertisement(
            protocolMajor: 1, pairable: flags & 1 != 0, hasBond: flags & 2 != 0, hasGPS: flags & 4 != 0,
            supports5GHz: flags & 8 != 0, model: .esp32C5Devkitc1
        )
        #expect(advertisement.encoded == Data([0xFF, 0xFF, 0x01, UInt8(flags), 0x02]))
        #expect(BoardAdvertisement.parse(manufacturerData: advertisement.encoded) == advertisement)
    }

    @Test("Short ID comes from the NS-XXXX name only")
    func shortID() {
        #expect(BoardAdvertisement.shortID(fromName: "NS-ABCD") == "ABCD")
        #expect(BoardAdvertisement.shortID(fromName: "NS-abcd") == "ABCD")
        #expect(BoardAdvertisement.shortID(fromName: "NS-") == nil)
        #expect(BoardAdvertisement.shortID(fromName: "NS-XYZ1") == nil)
        #expect(BoardAdvertisement.shortID(fromName: "Headphones") == nil)
        #expect(BoardAdvertisement.shortID(fromName: nil) == nil)
    }

    @Test("Characteristic UUIDs follow protocol.md section 2")
    func uuids() {
        #expect(BoardCharacteristic.info.uuidString == "72AA0002-0D8E-4D18-8877-63C24ABE28D2")
        #expect(BoardCharacteristic.ota.uuidString == "72AA0007-0D8E-4D18-8877-63C24ABE28D2")
        #expect(BoardCharacteristic(uuidString: "72aa0005-0d8e-4d18-8877-63c24abe28d2") == .records)
        #expect(BoardCharacteristic(uuidString: BoardGATT.serviceUUID) == nil)
        #expect(!BoardCharacteristic.info.isEncrypted && BoardCharacteristic.control.isEncrypted)
    }

    @Test("CoreBluetooth errors map to board link errors")
    func errorMapping() {
        let stale = BLEError(NSError(domain: "CBErrorDomain", code: 14))
        #expect(stale.kind == .peerRemovedPairingInformation)
        #expect(stale.transportError == .bondMissing)
        #expect(BLEError(domain: "CBErrorDomain", code: 15).transportError == .pairingRejected)
        #expect(BLEError(domain: "CBATTErrorDomain", code: 5).transportError == .pairingRejected)
        #expect(BLEError(domain: "CBATTErrorDomain", code: 15).transportError == .pairingRejected)
        #expect(BLEError(domain: "CBATTErrorDomain", code: 8).kind == .insufficientAuthorization)
        #expect(BLEError(domain: "CBErrorDomain", code: 6).transportError == .timeout)
        #expect(BLEError(domain: "CBErrorDomain", code: 7).transportError == .notConnected)
        #expect(BLEError(domain: "Other", code: 14).kind == .other)
    }

    @Test("Reconnect backoff doubles up to the cap")
    func backoff() {
        let policy = ReconnectPolicy(initialDelay: .seconds(1), multiplier: 2, maxDelay: .seconds(30))
        #expect((1...7).map { policy.delay(afterAttempt: $0) } == [1, 2, 4, 8, 16, 30, 30].map { Duration.seconds($0) })
        #expect(ReconnectPolicy(initialDelay: .milliseconds(250), multiplier: 1.5).delay(afterAttempt: 3) == .milliseconds(563))
    }

    @Test("Drop deltas: counters grow, a reboot restarts them")
    func dropDeltas() {
        #expect(BoardRecordRouter.delta(10, 25, rebooted: false) == 15)
        #expect(BoardRecordRouter.delta(10, 4, rebooted: true) == 4)
        #expect(BoardRecordRouter.delta(10, 4, rebooted: false) == 4)
        let router = BoardRecordRouter()
        let id = ChannelPlannerTests.id(1)
        func status(_ uptime: UInt64, _ records: UInt32, raw: UInt32 = 0) -> NSBBoardStatus {
            .with {
                $0.uptimeMs = uptime
                $0.droppedRecords = records
                $0.droppedRawFrames = raw
            }
        }
        #expect(router.apply(status(1_000, 50), from: id).1.isEmpty)  // Baseline, older drops are not ours.
        #expect(router.apply(status(2_000, 70, raw: 3), from: id).1 == BoardDrops(records: 20, rawFrames: 3, rxFrames: 0))
        let (counters, drops) = router.apply(status(500, 5), from: id)  // Rebooted.
        #expect(drops.records == 5)
        #expect(counters.droppedRecords == 25 && counters.droppedRawFrames == 3)
    }
}
