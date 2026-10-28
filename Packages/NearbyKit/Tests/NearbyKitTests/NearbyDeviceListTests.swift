import Foundation
import Testing
@testable import NearbyKit

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func ad(
    _ id: UUID, at seconds: TimeInterval = 0, rssi: Int = -60, name: String? = nil, mfg: Data? = nil,
    services: [String] = []
) -> NearbyAdvertisement {
    NearbyAdvertisement(peripheralID: id, time: t0.addingTimeInterval(seconds), rssi: rssi, localName: name,
                        manufacturerData: mfg, serviceUUIDs: services)
}

@Suite struct NearbyAdvertisementTests {
    @Test func theCompanyIDIsTheFirstTwoBytesLittleEndian() {
        #expect(ad(UUID(), mfg: Data([0x4C, 0x00, 0x12])).companyID == 0x004C)
        #expect(ad(UUID(), mfg: Data([0x75, 0x00])).companyID == 0x0075)
        #expect(ad(UUID(), mfg: Data([0x01])).companyID == nil)
        #expect(ad(UUID()).companyID == nil)
    }

    @Test func aSlicedBufferIsReadFromItsStart() {
        let data = Data([0xFF, 0xE0, 0x00, 0x01]).dropFirst()
        #expect(NearbyAdvertisement.companyID(data) == 0x00E0)
    }
}

@Suite struct NearbyDeviceListTests {
    @Test func advertisementsFromOnePeripheralBecomeOneDevice() {
        var list = NearbyDeviceList()
        let id = UUID()
        list.record(ad(id, at: 0, rssi: -70))
        list.record(ad(id, at: 1, rssi: -65))
        #expect(list.count == 1)
        #expect(list[id]?.rssi == -65)
        #expect(list[id]?.firstHeard == t0)
        #expect(list[id]?.lastHeard == t0.addingTimeInterval(1))
        #expect(list[id]?.history.count == 2)
    }

    @Test func aNameFromTheScanResponseIsKeptWhenLaterAdvertisementsHaveNone() {
        var list = NearbyDeviceList()
        let id = UUID()
        list.record(ad(id, at: 0, name: "Demo Speaker", mfg: Data([0x75, 0x00])))
        list.record(ad(id, at: 1, name: nil, mfg: nil))
        list.record(ad(id, at: 2, name: "  "))
        #expect(list[id]?.name == "Demo Speaker")
        #expect(list[id]?.companyID == 0x0075)
    }

    @Test func aMissingRSSIIsIgnored() {
        var list = NearbyDeviceList()
        list.record(ad(UUID(), rssi: 127))
        #expect(list.count == 0)
    }

    @Test func historyKeepsOnlyTheLastTwoMinutes() {
        var list = NearbyDeviceList()
        let id = UUID()
        list.record(ad(id, at: 0))
        list.record(ad(id, at: 60))
        list.record(ad(id, at: 150))
        let times = list[id]?.history.map { $0.time.timeIntervalSince(t0) }
        #expect(times == [60, 150])
    }

    @Test func aFastAdvertiserKeepsOneReadingPerHalfSecondForTheWholeWindow() {
        var list = NearbyDeviceList()
        let id = UUID()
        // 20 advertisements a second for three minutes.
        for i in 0..<(20 * 180) {
            list.record(ad(id, at: Double(i) * 0.05, rssi: -40 - i % 7))
        }
        let history = list[id]?.history ?? []
        #expect(history.count <= NearbyDeviceList.maxReadings)
        let span = (history.last?.time.timeIntervalSince(history.first?.time ?? t0)) ?? 0
        #expect(span > NearbyDeviceList.historyWindow - 1)
        #expect(list[id]?.rssi == -40 - (20 * 180 - 1) % 7)
    }

    @Test func aFullListDropsTheDeviceHeardLongestAgo() {
        var list = NearbyDeviceList(capacity: 2)
        let a = UUID(), b = UUID(), c = UUID()
        list.record(ad(a, at: 0))
        list.record(ad(b, at: 1))
        list.record(ad(a, at: 2))
        list.record(ad(c, at: 3))
        #expect(list.count == 2)
        #expect(list[b] == nil)
        #expect(list[a] != nil && list[c] != nil)
    }

    @Test func aHiddenDeviceStaysHiddenUntilTheListIsCleared() {
        var list = NearbyDeviceList()
        let id = UUID()
        list.record(ad(id))
        list.hide(id)
        list.record(ad(id, at: 1))
        #expect(list[id] == nil)
        list.removeAll()
        list.record(ad(id, at: 2))
        #expect(list[id] != nil)
    }

    @Test func sortsBySignalOrByLastHeard() {
        var list = NearbyDeviceList()
        let near = UUID(), far = UUID()
        list.record(ad(near, at: 0, rssi: -50))
        list.record(ad(far, at: 5, rssi: -90))
        let now = t0.addingTimeInterval(6)
        #expect(list.sorted(by: .signal, now: now).map(\.id) == [near, far])
        #expect(list.sorted(by: .recent, now: now).map(\.id) == [far, near])
    }

    @Test func aStrongDeviceNotHeardLatelySortsAfterWeakerRecentOnes() {
        var list = NearbyDeviceList()
        let stale = UUID(), weak = UUID()
        list.record(ad(stale, at: 0, rssi: -40))
        list.record(ad(weak, at: 50, rssi: -90))
        #expect(list.sorted(by: .signal, now: t0.addingTimeInterval(55)).map(\.id) == [weak, stale])
        #expect(list.sorted(by: .signal, now: t0.addingTimeInterval(20)).map(\.id) == [stale, weak])
    }
}

@Suite struct SimulatedNearbyScannerTests {
    @Test func theSameSeedGivesTheSameDevices() {
        let a = SimulatedNearbyScanner.makeProfiles(seed: 3).map(\.id)
        let b = SimulatedNearbyScanner.makeProfiles(seed: 3).map(\.id)
        let c = SimulatedNearbyScanner.makeProfiles(seed: 4).map(\.id)
        #expect(a == b)
        #expect(a != c)
    }

    @Test func startReportsPoweredOnThenAdvertisements() async {
        let scanner = SimulatedNearbyScanner(seed: 1, interval: .milliseconds(10))
        var events = scanner.events().makeAsyncIterator()
        scanner.start()
        #expect(await events.next() == .state(.poweredOn))
        var heard = 0
        while heard < 5, let event = await events.next() {
            if case .advertisement = event { heard += 1 }
        }
        scanner.stop()
        #expect(heard == 5)
    }
}
