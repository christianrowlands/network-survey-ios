import Destinations
import Foundation
import SurveyCore
import Testing
@testable import NetworkSurvey

@Suite("Data screens helpers") @MainActor
struct DataScreensUnitTests {
    @Test func advertisingDataSplitsIntoStructures() {
        // Flags, 16-bit service UUID 0x180F, complete name "Tag", then zero padding.
        let data = Data([0x02, 0x01, 0x06, 0x03, 0x03, 0x0F, 0x18, 0x04, 0x09, 0x54, 0x61, 0x67, 0x00, 0x00])
        let parts = ADStructure.split(data)
        #expect(parts.map(\.type) == [0x01, 0x03, 0x09])
        #expect(parts[2].value == Data("Tag".utf8))
        #expect(parts[0].typeName == "Flags (0x01)")
    }

    @Test func truncatedAdvertisingDataIsKeptUnparsed() {
        let data = Data([0x02, 0x01, 0x06, 0x05, 0xFF, 0x4C])
        let parts = ADStructure.split(data)
        #expect(parts.count == 2)
        #expect(parts[1].type == 0)
        #expect(parts[1].value == Data([0x05, 0xFF, 0x4C]))
    }

    private func point(_ id: String, _ lat: Double, _ lon: Double, rssi: Int = -60) -> MapPoint {
        MapPoint(kind: .ap, identity: id, label: nil, latitude: lat, longitude: lon, rssi: rssi, band: 1, randomized: false)
    }

    @Test func clustersGroupNearbyPointsAndKeepFarOnesApart() {
        let points = [
            point("a", 38.0, -77.0), point("b", 38.0001, -77.0001, rssi: -40), point("c", 38.0002, -77.0),
            point("far", 38.009, -77.009),
        ]
        let zoomedOut = MapClusterer.clusters(points, latitudeDelta: 0.01, longitudeDelta: 0.01, size: CGSize(width: 400, height: 400))
        #expect(zoomedOut.count == 2)
        let group = zoomedOut.first { $0.points.count == 3 }
        #expect(group?.strongest.identity == "b")
        #expect(zoomedOut.contains { $0.isSingle && $0.id == points[3].id })
        #expect(zoomedOut.map(\.points.count).reduce(0, +) == points.count)

        let zoomedIn = MapClusterer.clusters(points, latitudeDelta: 0.0001, longitudeDelta: 0.0001, size: CGSize(width: 400, height: 400))
        #expect(zoomedIn.count == 4)
        #expect(zoomedIn.filter(\.isSingle).count == 4)
    }

    @Test func clusterCentersStayAtLeastACellApart() {
        // A dense walk: 300 points along a line, viewed at street scale.
        let points = (0..<300).map { point("p\($0)", 38.0 + Double($0) * 0.00002, -77.0 + Double($0) * 0.00002) }
        let size = CGSize(width: 390, height: 700)
        let clusters = MapClusterer.clusters(points, latitudeDelta: 0.01, longitudeDelta: 0.006, size: size)
        let cellLat = 0.01 * 60 / 700, cellLon = 0.006 * 60 / 390
        for (i, a) in clusters.enumerated() {
            for b in clusters[(i + 1)...] {
                let dx = (a.coordinate.longitude - b.coordinate.longitude) / cellLon
                let dy = (a.coordinate.latitude - b.coordinate.latitude) / cellLat
                #expect(dx * dx + dy * dy >= 0.25, "clusters \(a.id) and \(b.id) overlap")
            }
        }
        #expect(clusters.map(\.points.count).reduce(0, +) == 300)
    }

    @Test func trackIsThinnedKeepingEnds() {
        let thinned = TrackThinner.thin(Array(0..<10_000), limit: 100)
        #expect(thinned.count == 100)
        #expect(thinned.first == 0 && thinned.last == 9_999)
        #expect(TrackThinner.thin([1, 2, 3], limit: 100) == [1, 2, 3])
    }

    @Test func securitySuitesAreNamed() {
        #expect(DataFormat.akmSuites("1027074,1027080") == "PSK, SAE")
        #expect(DataFormat.cipherSuites("1027076") == "CCMP-128")
        #expect(DataFormat.akmSuites("5304834") == "PSK")
        #expect(DataFormat.akmSuites("305419896") == "12-34-56:120")
    }

    @Test func blePrivateAddresses() {
        #expect(DataFormat.isPrivateBLEAddress("4A:11:22:33:44:55", addressType: 2))
        #expect(!DataFormat.isPrivateBLEAddress("C2:00:5E:00:53:99", addressType: 2))
        #expect(!DataFormat.isPrivateBLEAddress("4A:11:22:33:44:55", addressType: 1))
    }

    @Test func stableOrderKeepsPositions() {
        let merged = StableOrder.merge(["b", "a", "c"], ["a", "d", "b"], id: \.self)
        #expect(merged == ["b", "a", "d"])
    }

    @Test func hexDumpWrapsAtSixteenBytes() {
        let text = DataFormat.hex(Data(0..<18))
        #expect(text == "00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F\n10 11")
    }

    @Test func distancesFollowUnits() {
        #expect(DataFormat.distance(100, units: .metric).contains("100"))
        #expect(DataFormat.distance(2000, units: .metric).contains("2"))
        #expect(DataFormat.distance(100, units: .imperial).contains("328"))
    }

    @Test func companyNamesComeFromTheBundledSIGList() {
        #expect(BLECompanies.names.count > 3000)
        #expect(BLECompanies.name(for: 0x004C) == "Apple, Inc.")
        #expect(BLECompanies.name(for: 0x02E5)?.hasPrefix("Espressif") == true)
        #expect(BLECompanies.hexID(0x6) == "0x0006")
        #expect(BLEServiceUUIDs.members.count > 500 && BLEServiceUUIDs.services.count > 50)
        #expect(BLEServiceUUIDs.shortID("0000FE9F-0000-1000-8000-00805f9b34fb") == 0xFE9F)
        #expect(BLEServiceUUIDs.shortID("12345678-0000-1000-8000-00805F9B34FB") == nil)
        #expect(BLEServiceUUIDs.name(forUUID: "FE9F") != nil)
        #expect(BLEServiceUUIDs.name(forUUID: "00001812-0000-1000-8000-00805f9b34fb") == "Human Interface Device")
        #expect(BLEServiceUUIDs.display("00001812-0000-1000-8000-00805f9b34fb") == "0x1812")
        #expect(BLEServiceUUIDs.display("6e400001-b5a3-f393-e0a9-e50e24dcca9e") == "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    }

    @Test func assignedNumbersYAMLParses() {
        let yaml = """
            # header
            company_identifiers:

              - value: 0x004C
                name: 'Apple, Inc.'
              - value: 0x0123
                name: "Xi'an Example"
             - uuid: 0xFEFF
               name: GN Netcom
              - value: 0x0124
                name: 'It''s Quoted'
            """
        #expect(AssignedNumbers.parse(yaml, idKey: "value") == [0x4C: "Apple, Inc.", 0x123: "Xi'an Example", 0x124: "It's Quoted"])
        #expect(AssignedNumbers.parse(yaml, idKey: "uuid") == [0xFEFF: "GN Netcom"])
    }

    @Test func licensesAreBundledWithFullTexts() {
        let licenses = ThirdPartyLicense.bundled()
        #expect(licenses.count >= 25)
        #expect(licenses.allSatisfy { $0.text.count > 300 })
        #expect(licenses.contains { $0.name == "GRDB.swift" && $0.license == "MIT" })
        #expect(licenses.contains { $0.name == "Bluetooth SIG Assigned Numbers" && $0.text.contains("bitbucket.org/bluetooth-SIG") })
        #expect(licenses.first { $0.name == "SwiftNIO" }?.text.contains("The SwiftNIO Project") == true)
    }

    @Test func surveyFoldersListNewestFirstWithSizes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("files-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let surveys = SurveyFiles.surveysDirectory(root: root)
        for name in ["20261001-090000", "20261002-100000"] {
            let folder = surveys.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 10).write(to: folder.appendingPathComponent("craxiom-wifi-\(name).csv"))
            try Data(repeating: 0x41, count: 5).write(to: folder.appendingPathComponent("craxiom-wigle-\(name).csv"))
        }
        let folders = SurveyFiles.folders(root: root, sessions: [])
        #expect(folders.map(\.name) == ["20261002-100000", "20261001-090000"])
        #expect(folders[0].totalBytes == 15)
        #expect(folders[0].files.map(\.kindName) == ["Wi-Fi CSV", "WiGLE CSV"])
        #expect(folders[0].isRecording == false)

        try SurveyFiles.delete(folders[0])
        #expect(SurveyFiles.folders(root: root, sessions: []).map(\.name) == ["20261001-090000"])
    }

    @Test func registrationLinksAreValidated() async {
        let settings = SettingsModel(store: .inMemory())
        let model = RegistrationModel(
            client: .init(transport: URLSessionTransportStub()), credentials: InMemoryCredentialStore(), settings: settings
        ) {
            .init(deviceID: "id", deviceName: "name", deviceModel: "model", osVersion: "iOS 18.0", appVersion: "1.0")
        }
        #expect(!model.receive("not a link"))
        #expect(model.linkError != nil)
        #expect(!model.receive("https://networksurvey.app/app/register?token=t&workspace_id=w&api_url=http://example.com"))
        #expect(model.linkError == RegistrationModel.message(for: .serverNotHTTPS))
        #expect(model.receive(" https://networksurvey.app/app/register?token=t&workspace_id=w&api_url=https://api.example.com&workspace_name=Team \n"))
        #expect(model.pendingLink?.workspaceName == "Team")
        #expect(model.linkError == nil)
    }
}

/// Never called: link validation happens before any request.
private struct URLSessionTransportStub: NSAnalyticsTransport {
    func send(_ request: URLRequest, body: Data, taskID: String) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}
