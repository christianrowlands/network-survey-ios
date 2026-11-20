import Foundation
import Testing
@testable import NSMessaging

/// Reading Find My advertisements: Apple's company ID, payload type 0x12 and
/// the status byte's device type. Matches the Android app's FindMyTest.
@Suite("Find My")
struct FindMyTests {
    /// Apple's company ID, little endian, ahead of `payload`.
    private func apple(_ payload: [UInt8]) -> [UInt8] { [0x4C, 0x00] + payload }

    @Test("The status byte says what sent it")
    func statusByte() {
        // Away from its owner: type 0x12, length 0x19, then the status byte.
        #expect(FindMy.device(manufacturerData: apple([0x12, 0x19, 0x00, 0xAA, 0xBB])) == .appleDevice)
        #expect(FindMy.device(manufacturerData: apple([0x12, 0x19, 0x10, 0xAA, 0xBB])) == .airTag)
        #expect(FindMy.device(manufacturerData: apple([0x12, 0x19, 0x20, 0xAA, 0xBB])) == .accessory)
        #expect(FindMy.device(manufacturerData: apple([0x12, 0x19, 0x30, 0xAA, 0xBB])) == .airPods)
    }

    @Test("Near its owner the short form is read, other status bits ignored")
    func shortForm() {
        #expect(FindMy.device(manufacturerData: apple([0x12, 0x02, 0xD4, 0xAA])) == .airTag)
    }

    @Test("Only AirTags and Find My accessories are trackers")
    func trackers() {
        #expect(FindMyDevice.airTag.isTracker && FindMyDevice.accessory.isTracker)
        #expect(!FindMyDevice.appleDevice.isTracker && !FindMyDevice.airPods.isTracker)
        #expect(FindMyDevice.trackerValues == [1, 2])
    }

    @Test("Other Apple payloads and other companies are not Find My")
    func notFindMy() {
        // Proximity Pairing (0x07) from AirPods, and Nearby Info (0x10).
        #expect(FindMy.device(manufacturerData: apple([0x07, 0x19, 0x10, 0xAA, 0xBB])) == nil)
        #expect(FindMy.device(manufacturerData: apple([0x10, 0x05, 0xAA, 0xBB])) == nil)
        #expect(FindMy.device(manufacturerData: [0x75, 0x00, 0x12, 0x19, 0x10]) == nil)
        // Apple's ID big endian is another company (0x4C00).
        #expect(FindMy.device(manufacturerData: [0x00, 0x4C, 0x12, 0x19, 0x10]) == nil)
    }

    @Test("Missing or short data is not Find My")
    func shortData() {
        #expect(FindMy.device(manufacturerData: [UInt8]()) == nil)
        #expect(FindMy.device(manufacturerData: [0x4C]) == nil)
        #expect(FindMy.device(manufacturerData: apple([])) == nil)
        #expect(FindMy.device(manufacturerData: apple([0x12])) == nil)
        #expect(FindMy.device(manufacturerData: apple([0x12, 0x19])) == nil)
    }

    @Test("A Data slice with a nonzero start index is read")
    func dataSlice() {
        let data = Data([0xFF] + apple([0x12, 0x19, 0x20])).dropFirst()
        #expect(FindMy.device(manufacturerData: data) == .accessory)
    }

    @Test("Advertising data is read from its manufacturer data structure")
    func advertisingData() {
        // Flags, then an AirTag's manufacturer data.
        let airTag = Data([0x02, 0x01, 0x06, 0x07, 0xFF, 0x4C, 0x00, 0x12, 0x02, 0x10, 0x01])
        #expect(FindMy.device(advertisingData: airTag) == .airTag)
        // A name and no manufacturer data.
        #expect(FindMy.device(advertisingData: Data([0x03, 0x09, 0x41, 0x42])) == nil)
        #expect(FindMy.device(advertisingData: Data()) == nil)
        // A truncated manufacturer data structure is not read.
        #expect(FindMy.device(advertisingData: Data([0x09, 0xFF, 0x4C, 0x00, 0x12, 0x02, 0x10])) == nil)
    }
}
