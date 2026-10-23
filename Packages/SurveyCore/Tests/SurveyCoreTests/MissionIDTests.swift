import Foundation
import Testing
@testable import SurveyCore

@Suite("Mission ID and record numbers")
struct MissionIDTests {
    @Test("Matches the Android format")
    func format() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15 08:00:00 UTC
        let utc = try #require(TimeZone(identifier: "UTC"))
        let missionID = MissionID.make(installID: Fixtures.installID, startedAt: start, timeZone: utc)
        #expect(missionID == "NS 00000000 20270115-080000")
    }

    @Test("Uses the device serial number as the device ID")
    func matchesSerial() {
        let installID = UUID(uuidString: "8c2e1f7a-0b5d-4e16-9a3f-2d7c4b6e1a90")!
        let identity = DeviceIdentity(installID: installID, deviceName: "iPhone-8C2E")
        #expect(identity.deviceSerialNumber == "8C2E1F7A")
        #expect(MissionID.make(installID: installID, startedAt: .now).hasPrefix("NS \(identity.deviceSerialNumber) "))
    }

    @Test("Demo format")
    func demo() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let missionID = MissionID.makeDemo(startedAt: Date(timeIntervalSince1970: 1_800_000_000), timeZone: utc)
        #expect(missionID == "NS DEMO 20270115-080000")
    }

    @Test("Uses the given time zone")
    func timeZone() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(MissionID.timestamp(start, timeZone: tokyo) == "20270115-170000")
    }

    @Test("Record numbers count per message type from 1")
    func recordNumbers() {
        var numbers = RecordNumbers()
        #expect(numbers.take(.wifiBeacon) == 1)
        #expect(numbers.take(.wifiBeacon) == 2)
        #expect(numbers.take(.bluetooth) == 1)
        #expect(numbers.take(.deviceStatus) == 1)
        #expect(numbers.take(.wifiBeacon) == 3)
        #expect(numbers.peek(.wifiProbeRequest) == 1)
    }

    @Test("Record numbers continue after a resume")
    func resumedNumbers() {
        var numbers = RecordNumbers(startingAfter: [.wifiBeacon: 41, .bluetooth: 2])
        #expect(numbers.take(.wifiBeacon) == 42)
        #expect(numbers.take(.bluetooth) == 3)
        #expect(numbers.take(.wifiStation) == 1)
    }
}
