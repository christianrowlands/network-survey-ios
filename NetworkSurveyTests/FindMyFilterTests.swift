import Foundation
import NearbyKit
import NSMessaging
import SurveyCore
import Testing
@testable import NetworkSurvey

@Suite("Find My tag and BLE filters") @MainActor
struct FindMyFilterTests {
    @Test func namedAndTrackerFiltersApplyToBluetoothOnly() {
        var filters = ListFilters()
        filters.namedOnly = true
        filters.findMyTrackersOnly = true
        let ble = filters.query(for: .ble)
        #expect(ble.namedOnly && ble.findMyTrackersOnly)
        #expect(filters.isFiltering(.ble))
        for kind in [ListKind.aps, .clients, .probeNetworks, .probeClients] {
            let query = filters.query(for: kind)
            #expect(!query.namedOnly && !query.findMyTrackersOnly)
            #expect(!filters.isFiltering(kind))
        }
    }

    @Test func eitherFilterAloneCountsAsFiltering() {
        var named = ListFilters()
        named.namedOnly = true
        #expect(named.isFiltering(.ble))
        var trackers = ListFilters()
        trackers.findMyTrackersOnly = true
        #expect(trackers.isFiltering(.ble))
        #expect(!ListFilters().isFiltering(.ble))
    }

    @Test func onlyTrackersGetATag() {
        #expect(FindMyFormat.tag(.airTag) == "AirTag")
        #expect(FindMyFormat.tag(.accessory) == "Find My")
        #expect(FindMyFormat.tag(.appleDevice) == nil)
        #expect(FindMyFormat.tag(.airPods) == nil)
        #expect(FindMyFormat.tag(nil) == nil)
        #expect(FindMyDevice.allCases.map(FindMyFormat.label)
            == ["Apple device", "AirTag", "Tracker or accessory", "AirPods"])
    }

    @Test func nearbyDevicesReadCoreBluetoothManufacturerData() {
        var list = NearbyDeviceList()
        let id = UUID()
        list.record(NearbyAdvertisement(
            peripheralID: id, time: .now, rssi: -60, manufacturerData: Data([0x4C, 0x00, 0x12, 0x19, 0x10, 0xAA])
        ))
        #expect(list[id]?.findMy == .airTag)
        let other = UUID()
        list.record(NearbyAdvertisement(peripheralID: other, time: .now, rssi: -60, manufacturerData: Data([0x4C, 0x00, 0x10, 0x05])))
        #expect(list[other]?.findMy == nil)
    }
}
