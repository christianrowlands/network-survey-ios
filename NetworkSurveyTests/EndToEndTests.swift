import BoardKit
import BoardProtocol
import Destinations
import Foundation
import NSMessaging
import SurveyCore
import Testing
@testable import NetworkSurvey

/// A full survey through the real app wiring (AppModel, DestinationFactory,
/// SurveyCore, BoardKit's Bluetooth transport) with two simulated boards and
/// every destination on, checked against what reached the local servers.
/// Runs only under scripts/e2e.sh, which starts those servers.
///
/// The boards are simulated behind the Bluetooth transport (not the demo
/// transport), so the app treats them as real boards and NS Analytics is
/// allowed; `-NSSimulatedWalk` gives them the demo's walk for location.
@MainActor
@Suite("End to end with simulated boards", .serialized, .enabled(if: HarnessClient.fromEnvironment != nil))
struct EndToEndTests {
    static let surveySeconds = 45
    static let dropBoardAt = 12
    static let deviceName = "E2E-Phone"
    static let topicPrefix = "ns-e2e/"

    struct Files {
        var wifi: CSVTable
        var bluetooth: CSVTable
        var client: CSVTable
        var probe: CSVTable
        var wigle: CSVTable
        var pcap: URL
    }

    @Test("Two boards, every destination: counts agree across UI, database, files and servers", .timeLimit(.minutes(5)))
    func fullSurvey() async throws {
        let harness = try #require(HarnessClient.fromEnvironment)
        let ports = try await harness.ports()
        try await harness.reset()

        var options = LaunchOptions()
        options.uiTesting = true
        options.simulatedWalk = true
        let model = AppModel(options: options)
        await model.launch(restoredByBluetooth: false)
        try await configure(model, ports: ports)
        print("E2E: configured, harness \(harness.base)")

        // Two boards behind the Bluetooth transport, already paired with this phone.
        let central = SimulatedBLECentral(boardCount: 2, seed: 11, pairedWithPhone: [0, 1])
        central.startClock()
        defer { central.shutdown() }
        await model.transport.attachBluetooth(BLEBoardTransport(central: central))
        for profile in central.profiles {
            #expect(await model.connect(BoardID(profile.peripheralID)) == nil)
        }
        #expect(await eventually { model.boardManager.readyBoards.count == 2 })
        print("E2E: boards ready \(model.boardManager.readyBoards.count)")
        let boards = central.boardIDs

        // Privacy: a zone the walk crosses about 30 s in, and an ignored AP near the walk.
        let walk = model.location.demo
        let zone = PrivacyZone(name: "E2E zone", center: walk.sample(atSeconds: 30).point, radiusMeters: 8)
        let (ignored, neighbour) = Self.accessPointsNearWalk(central.world)
        model.settings[Settings.privacyZones] = [zone]
        model.settings[Settings.ignoreList] = [IgnoreEntry(kind: .bssid, value: ignored)]

        // People take a while to press Start; the walk's fixes must still be fresh.
        try await Task.sleep(for: .seconds(12))
        await model.startSurvey()
        #expect(await eventually { model.survey.isRunning })
        let missionId = try #require(model.survey.missionId)
        let sessionID = try #require(model.survey.session?.id)
        #expect(missionId.hasPrefix("NS \(model.identity.deviceSerialNumber) "))
        let started = ContinuousClock.now
        // Channel split with BLE on and two boards: one board surveys every
        // Wi-Fi channel, the other becomes the BLE sniffer.
        let roles = boards.compactMap { model.boardManager.boards[$0]?.assignment?.role }
        let wifiBoards = Set(boards.filter { model.boardManager.boards[$0]?.assignment?.role != .bleSniffer }.map(\.description))
        #expect(roles.count == 2 && roles.filter { $0 == .bleSniffer }.count == 1)
        print("E2E: survey running \(missionId)")

        // A board walks out of range for 5 s (less than the 10 s before others
        // take over its channels): a gap opens, the board keeps surveying into
        // its buffer, BoardManager reconnects it and the buffered records arrive.
        try await Task.sleep(until: started + .seconds(Self.dropBoardAt), clock: .continuous)
        let dropped = try #require(boards.first { wifiBoards.contains($0.description) })
        central.injectLinkLoss(dropped, outOfRange: true)
        try await Task.sleep(for: .seconds(5))
        central.setInRange(true, dropped)
        #expect(await eventually(timeout: .seconds(20)) {
            let gaps = try? await model.store.read { try StoreQueries.gapEvents($0, sessionID: sessionID) }
            return gaps?.first?.endedAt != nil
        })
        try await Task.sleep(until: started + .seconds(Self.surveySeconds), clock: .continuous)
        print("E2E: stopping")
        await model.stopSurvey()
        print("E2E: stopped")
        #expect(model.survey.state == .idle)

        // Stop flushes everything: files closed, streams drained, the upload finishes.
        let snapshots = await model.controller.destinationSnapshots()
        #expect(await eventually(timeout: .seconds(30)) {
            let state = await model.uploader.state()
            return state.pending == 0 && state.totalUploaded > 0
        })
        let numbers = try await model.store.recordNumbers(sessionID: sessionID)
        func count(_ type: MessageType) -> Int { numbers.peek(type) - 1 }
        let expectedStreamed = count(.wifiBeacon) + count(.wifiProbeRequest) + count(.bluetooth) + count(.deviceStatus)
        var counts = try await harness.counts()
        #expect(await eventually {
            counts = (try? await harness.counts()) ?? counts
            return counts.mqtt.values.reduce(0) { $0 + $1.count } >= expectedStreamed
                && counts.grpc.values.reduce(0) { $0 + $1.count } >= expectedStreamed
        })

        print("E2E: uploads and streams settled")
        let files = try Self.readFiles(snapshots)
        let report = try await harness.checkPcap(files.pcap)
        try await verify(model: model, sessionID: sessionID, missionId: missionId, wifiBoards: wifiBoards,
                         count: count, files: files, counts: counts, snapshots: snapshots, pcap: report)
        try verifyPrivacy(model: model, zone: zone, ignored: ignored, neighbour: neighbour, files: files, counts: counts)
        #expect(report.bssids?.contains(ignored) == false, "the ignored AP's raw frames")
        try await verifyGap(model: model, sessionID: sessionID, board: dropped, files: files)
        print("E2E summary: mission \(missionId)")
        for type in MessageType.allCases { print("E2E summary: \(type.rawValue) \(count(type))") }
        print("E2E summary: pcap \(report.packets ?? -1) frames, filtered \(model.survey.counters.filtered)")
        print("E2E summary: unique \(model.survey.uniqueCounts)")
        print("E2E summary: MQTT \(counts.mqtt.mapValues(\.count)), gRPC \(counts.grpc.mapValues(\.count))")
        print("E2E summary: NS Analytics \(counts.nsAnalytics.mapValues(\.count)) skipped \(counts.nsAnalyticsSkipped) in \(counts.nsAnalyticsBatches) batches")
        print("E2E summary: WiGLE rows \(files.wigle.rows.count), gaps \(try await model.store.read { try StoreQueries.gapEvents($0, sessionID: sessionID) }.map { "\($0.reason) \(($0.endedAt ?? $0.startedAt).timeIntervalSince($0.startedAt)) s" })")
    }

    // MARK: - Setup

    private func configure(_ model: AppModel, ports: HarnessClient.Ports) async throws {
        let settings = model.settings
        settings[Settings.surveyWifiAP] = true
        settings[Settings.surveyWifiClient] = true
        settings[Settings.surveyBLE] = true
        settings[Settings.surveyRawFrames] = true
        settings[Settings.destinationLogFiles] = true
        settings[Settings.logWigleCSV] = true
        settings[Settings.destinationMQTT] = true
        settings[Settings.mqttHost] = "127.0.0.1"
        settings[Settings.mqttPort] = ports.mqttPort
        settings[Settings.mqttTLSEnabled] = false
        settings[Settings.mqttTopicPrefix] = Self.topicPrefix
        settings[Settings.destinationGRPC] = true
        settings[Settings.grpcHost] = "127.0.0.1"
        settings[Settings.grpcPort] = ports.grpcPort
        settings[Settings.deviceName] = Self.deviceName
        settings[Settings.deviceStatusIntervalSeconds] = 10
        // Upload when the survey stops; probe requests on (the server answers "skipped").
        settings[Settings.nsAnalyticsUploadIntervalMinutes] = 0
        settings[Settings.nsAnalyticsUploadProbeRecords] = true

        // Register through the real client; the link checks (https, public host)
        // are the registration screen's and are covered by unit tests.
        let link = NSAnalyticsLink(
            token: "e2e-registration-token", workspaceID: "e2e-workspace",
            apiURL: try #require(URL(string: "http://127.0.0.1:\(ports.httpPort)/"))
        )
        let registration = try await model.nsAnalyticsClient.register(link, device: .init(
            deviceID: model.identity.deviceSerialNumber, deviceName: Self.deviceName, deviceModel: "iPhone",
            osVersion: "iOS 18.0", appVersion: Bundle.main.shortVersion
        ))
        model.nsAnalyticsCredentials.save(registration)
        settings[Settings.destinationNSAnalytics] = true
        #expect(model.uploader.isRegistered)
    }

    /// The AP nearest the boards' position 20 s in (ignored) and the next
    /// nearest one (which must show up, so the ignored one would have too).
    static func accessPointsNearWalk(_ world: SimulatedWorld) -> (ignored: String, neighbour: String) {
        let here = SimulatedWorld.surveyorPosition(atMs: 20_000)
        let byDistance = world.accessPoints.filter { $0.channel <= 14 }.sorted {
            hypot($0.position.x - here.x, $0.position.y - here.y) < hypot($1.position.x - here.x, $1.position.y - here.y)
        }
        let names = byDistance.prefix(2).map { $0.bssid.map { String(format: "%02x", $0) }.joined(separator: ":") }
        return (names[0], names[1])
    }

    static func readFiles(_ snapshots: [String: DestinationSnapshot]) throws -> Files {
        let csv = snapshots[DestinationKind.nsCSV.rawValue]?.files.map(\.url) ?? []
        // "craxiom-wifi-" + timestamp, not "craxiom-wifi-client-..." or "craxiom-wifi-probe-...".
        func file(_ prefix: String) throws -> URL {
            try #require(csv.first { url in
                let name = url.lastPathComponent
                return name.hasPrefix(prefix) && name.dropFirst(prefix.count).first?.isNumber == true
            }, "no \(prefix) file")
        }
        return Files(
            wifi: try CSVTable(url: file("craxiom-wifi-")),
            bluetooth: try CSVTable(url: file("craxiom-bluetooth-")),
            client: try CSVTable(url: file("craxiom-wifi-client-")),
            probe: try CSVTable(url: file("craxiom-wifi-probe-")),
            wigle: try CSVTable(url: try #require(snapshots[DestinationKind.wigle.rawValue]?.files.first?.url), preHeaderLines: 1),
            pcap: try #require(snapshots[DestinationKind.pcap.rawValue]?.files.first?.url)
        )
    }

    // MARK: - Checks

    private func verify(
        model: AppModel, sessionID: String, missionId: String, wifiBoards: Set<String>, count: (MessageType) -> Int,
        files: Files, counts: HarnessClient.Counts, snapshots: [String: DestinationSnapshot],
        pcap: HarnessClient.PcapReport
    ) async throws {
        let survey = model.survey
        let serial = model.identity.deviceSerialNumber
        for type in MessageType.allCases {
            #expect(count(type) > 0, "no \(type) records")
            // The survey screen's per-protocol record counts.
            #expect(survey.counters.delivered[type] == count(type), "UI count for \(type)")
        }

        // Database: the session row and unique items match the screen and the files.
        let row = try #require(try await model.store.read { try StoreQueries.sessions($0) }.first { $0.id == sessionID })
        #expect(row.missionId == missionId && row.stoppedAt != nil)
        let stored = try await model.store.read { try StoreQueries.counts($0, sessionID: sessionID) }
        let records = count(.wifiBeacon) + count(.wifiProbeRequest) + count(.wifiStation) + count(.bluetooth)
        #expect(stored.observations == records)
        #expect(survey.uniqueCounts == stored, "UI unique counts")
        #expect(Set(files.wifi.column("bssid")).count == stored.accessPoints)
        #expect(Set(files.client.column("sourceAddress")).count == stored.clients)
        #expect(Set(files.bluetooth.column("sourceAddress")).count == stored.bleDevices)
        let finalState = model.activityState()
        #expect(finalState.recordCount == records && finalState.accessPoints == stored.accessPoints, "Live Activity totals")

        // NS CSV: one row per record, the mission ID on each, numbers 1...n.
        let tables: [(MessageType, CSVTable)] = [
            (.wifiBeacon, files.wifi), (.bluetooth, files.bluetooth), (.wifiStation, files.client), (.wifiProbeRequest, files.probe),
        ]
        for (type, table) in tables {
            #expect(table.rows.count == count(type), "CSV rows for \(type)")
            #expect(Set(table.column("missionId")) == [missionId])
            #expect(Set(table.column("deviceSerialNumber")) == [serial])
            #expect(table.column("recordNumber").compactMap { Int($0) }.isOneToCount, "CSV numbers for \(type)")
        }
        #expect(Set(files.client.column("boardId") + files.probe.column("boardId")) == wifiBoards)
        let csvRows = tables.reduce(0) { $0 + $1.1.rows.count }
        #expect(snapshots[DestinationKind.nsCSV.rawValue]?.recordsAccepted == csvRows)

        // WiGLE: the 1.6 pre-header and header, one row per located AP and BLE record.
        #expect(files.wigle.preamble.first?.hasPrefix("WigleWifi-1.6,appRelease=") == true)
        #expect(files.wigle.header == WiGLEDestination.header)
        let locatedAPs = files.wifi.rows.filter { !GeoPoint(row: $0).isZero }.count
        let locatedBLE = files.bluetooth.rows.filter { !GeoPoint(row: $0).isZero }.count
        let locatedProbes = files.probe.rows.filter { !GeoPoint(row: $0).isZero }.count
        #expect(files.wigle.rows.count == locatedAPs + locatedBLE)
        #expect(files.wigle.rows.filter { $0["Type"] == "WIFI" }.count == locatedAPs)
        #expect(Double(locatedAPs) > Double(count(.wifiBeacon)) * 0.9, "most records located")

        // MQTT: one message per record on each NS Messaging topic, none on the
        // experimental station topic (off by default), device name stamped.
        let topics: [(MessageType, String)] = [
            (.wifiBeacon, MQTTTopic.wifiBeacon), (.wifiProbeRequest, MQTTTopic.wifiProbeRequest),
            (.bluetooth, MQTTTopic.bluetooth), (.deviceStatus, MQTTTopic.deviceStatus),
        ]
        for (type, topic) in topics {
            let channel = counts.mqtt[Self.topicPrefix + topic] ?? HarnessClient.Channel()
            #expect(channel.count == count(type), "MQTT \(topic)")
            #expect(channel.recordNumbers.isOneToCount, "MQTT numbers on \(topic)")
            #expect(channel.missionIds == [missionId] && channel.serials == [serial])
            #expect(channel.deviceNames == [Self.deviceName])
        }
        #expect(counts.mqtt[Self.topicPrefix + MQTTTopic.wifiStation] == nil)
        #expect(Set(counts.mqtt.keys).isSubset(of: Set(topics.map { Self.topicPrefix + $0.1 })))
        #expect(counts.mqttUnparsed == 0)
        #expect(snapshots[DestinationKind.mqtt.rawValue]?.recordsAccepted == counts.mqtt.values.reduce(0) { $0 + $1.count })

        // gRPC: one message per record on each stream after one handshake.
        let methods: [(MessageType, String)] = [
            (.wifiBeacon, "StreamWifiBeaconSurvey"), (.wifiProbeRequest, "StreamWifiProbeRequestSurvey"),
            (.bluetooth, "StreamBluetoothSurvey"), (.deviceStatus, "StatusUpdate"),
        ]
        for (type, method) in methods {
            let channel = counts.grpc[method] ?? HarnessClient.Channel()
            #expect(channel.count == count(type), "gRPC \(method)")
            #expect(channel.recordNumbers.isOneToCount, "gRPC numbers on \(method)")
            #expect(channel.missionIds == [missionId] && channel.serials == [serial])
            #expect(channel.deviceNames == [Self.deviceName])
        }
        #expect(counts.handshakes == 1)
        #expect(snapshots[DestinationKind.grpc.rawValue]?.recordsAccepted == counts.grpc.values.reduce(0) { $0 + $1.count })
        for kind in [DestinationKind.mqtt, .grpc, .nsAnalytics] {
            #expect(snapshots[kind.rawValue]?.queueDepth == 0 || kind == .nsAnalytics, "\(kind) queue")
            #expect(snapshots[kind.rawValue]?.droppedRecords == 0, "\(kind) dropped")
        }

        // NS Analytics: located beacons, BLE and device status are stored;
        // probe requests (experimental, on here) are answered as skipped;
        // station records stay off by default. Records keep an empty device name.
        let located = { (channel: HarnessClient.Channel?) in channel?.locations.count ?? 0 }
        #expect(counts.registrations == 1)
        #expect(counts.nsAnalytics["wifi"]?.count == locatedAPs)
        #expect(counts.nsAnalytics["bluetooth"]?.count == locatedBLE)
        #expect(counts.nsAnalytics["device_status"]?.count == located(counts.mqtt[Self.topicPrefix + MQTTTopic.deviceStatus]))
        #expect(counts.nsAnalytics["wifi_probe_request"]?.count == locatedProbes)
        #expect(counts.nsAnalyticsSkipped == ["wifi_probe_request": locatedProbes])
        #expect(counts.nsAnalytics["wifi_station"] == nil)
        for (type, channel) in counts.nsAnalytics {
            #expect(channel.missionIds == [missionId] && channel.serials == [serial] && channel.deviceNames == [""], "\(type)")
            #expect(channel.locations.count == channel.count, "\(type) records without location")
            #expect(Set(channel.recordNumbers).count == channel.count, "\(type) duplicates")
        }
        let uploaded = counts.nsAnalytics.values.reduce(0) { $0 + $1.count }
        #expect(snapshots[DestinationKind.nsAnalytics.rawValue]?.recordsAccepted == uploaded)
        #expect(await model.uploader.state().totalUploaded == uploaded)

        // pcapng: valid for tshark, one frame per raw frame on the screen, one interface per Wi-Fi board.
        #expect(pcap.error == nil)
        #expect(pcap.badPackets == 0)
        #expect(survey.counters.rawFrames > 0)
        #expect(pcap.packets == survey.counters.rawFrames, "pcapng frames")
        #expect(snapshots[DestinationKind.pcap.rawValue]?.recordsAccepted == survey.counters.rawFrames)
        #expect(Set(pcap.interfaces ?? []) == wifiBoards, "one pcapng interface per Wi-Fi board")
        #expect(pcap.capinfos?.contains("802.11 plus radiotap") == true)

        // DeviceStatus every 10 s (first one after 1 s).
        let expectedStatus = Self.surveySeconds / 10 + 1
        #expect((expectedStatus - 1...expectedStatus + 1).contains(count(.deviceStatus)), "DeviceStatus cadence")
    }

    private func verifyPrivacy(
        model: AppModel, zone: PrivacyZone, ignored: String, neighbour: String, files: Files, counts: HarnessClient.Counts
    ) throws {
        // Nothing stored or sent from inside the zone (fail closed on accuracy).
        func inside(_ point: GeoPoint, accuracy: Double) -> Bool { !point.isZero && zone.contains(point, accuracy: accuracy) }
        for table in [files.wifi, files.bluetooth, files.client, files.probe] {
            #expect(!table.rows.contains { inside(GeoPoint(row: $0), accuracy: Double($0["accuracy"] ?? "") ?? 0) })
        }
        #expect(!files.wigle.rows.contains {
            inside(GeoPoint(latitude: Double($0["CurrentLatitude"] ?? "") ?? 0, longitude: Double($0["CurrentLongitude"] ?? "") ?? 0),
                   accuracy: Double($0["AccuracyMeters"] ?? "") ?? 0)
        })
        for channel in Array(counts.mqtt.values) + Array(counts.grpc.values) + Array(counts.nsAnalytics.values) {
            #expect(!channel.locations.contains { inside(GeoPoint(latitude: $0[0], longitude: $0[1]), accuracy: 0) })
        }
        #expect(model.survey.counters.filtered > 0)

        // The ignored AP appears nowhere (nor as a client's AP); its neighbour does.
        #expect(!files.wifi.column("bssid").contains(ignored))
        #expect(!files.client.column("bssid").contains(ignored))
        #expect(!files.probe.column("bssid").contains(ignored))
        #expect(!files.wigle.column("MAC").contains(ignored))
        for channel in [counts.mqtt[Self.topicPrefix + MQTTTopic.wifiBeacon], counts.grpc["StreamWifiBeaconSurvey"], counts.nsAnalytics["wifi"]] {
            #expect(channel?.addresses.contains(ignored) == false)
        }
        #expect(files.wifi.column("bssid").contains(neighbour), "the ignored AP's neighbour was heard")
    }

    private func verifyGap(model: AppModel, sessionID: String, board: BoardID, files: Files) async throws {
        let gaps = try await model.store.read { try StoreQueries.gapEvents($0, sessionID: sessionID) }
        let gap = try #require(gaps.first { $0.boardId == board.description && $0.reason.hasPrefix("linkLost") })
        let ended = try #require(gap.endedAt)
        #expect(ended.timeIntervalSince(gap.startedAt) > 4, "gap length")
        #expect(gaps.allSatisfy { $0.endedAt != nil })
        // Records the board buffered during the gap arrived with their own
        // times, and it kept surveying after it came back.
        let times = ISO8601DateFormatter()
        times.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let boardTimes = (files.probe.rows + files.client.rows)
            .filter { $0["boardId"] == board.description }
            .compactMap { times.date(from: $0["deviceTime"] ?? "") }
        #expect(boardTimes.contains { $0 > gap.startedAt.addingTimeInterval(1) && $0 < ended.addingTimeInterval(-1) }, "buffered records")
        #expect(boardTimes.contains { $0 > ended })
    }
}

private extension LocationSample {
    var point: GeoPoint { GeoPoint(latitude: latitude, longitude: longitude) }
}
