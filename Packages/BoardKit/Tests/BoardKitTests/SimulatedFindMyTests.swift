import Testing
@testable import BoardKit

@Suite("Simulated Find My devices")
struct SimulatedFindMyTests {
    /// The Find My status byte's device type bits, or nil when `advData` is
    /// not Apple Find My manufacturer data.
    private func findMyType(_ advData: [UInt8]) -> Int? {
        var index = 0
        while index + 1 < advData.count {
            let length = Int(advData[index])
            guard length > 0, index + length < advData.count else { return nil }
            let value = Array(advData[(index + 2)...(index + length)])
            if advData[index + 1] == 0xFF {
                guard value.count >= 5, value[0] == 0x4C, value[1] == 0x00, value[2] == 0x12 else { return nil }
                return Int((value[4] & 0x30) >> 4)
            }
            index += length + 1
        }
        return nil
    }

    @Test("Every world has one AirTag and one Find My accessory, and no other tracker")
    func trackers() {
        for seed in [UInt64(1), 7, 11, 42] {
            let world = SimulatedWorld(seed: seed)
            let types = world.bleDevices.compactMap { findMyType($0.advData) }.filter { $0 == 1 || $0 == 2 }
            #expect(types.sorted() == [1, 2], "seed \(seed)")
        }
    }

    @Test("Find My advertisements fit a legacy advertisement and use random static addresses")
    func wellFormed() {
        var rng = SeededGenerator(seed: 5)
        let devices = SimulatedWorld.makeFindMyDevices(rng: &rng)
        #expect(devices.count == 2)
        for device in devices {
            #expect(device.advData.count <= AdvertisingData.maxLegacyLength)
            #expect(Int(device.advData[0]) + 1 == device.advData.count)
            #expect(device.address[0] & 0xC0 == 0xC0 && device.addressType == .random)
            #expect(device.companyID == 0x004C && device.name.isEmpty)
        }
        #expect(devices[0].advData.count == AdvertisingData.maxLegacyLength)
    }
}
