import BoardKit
import Destinations
import Foundation
import SurveyCore
import Testing
@testable import NetworkSurvey

@MainActor
@Suite("Survey screen logic")
struct SurveyPresentationTests {
    @Test("Defaults: Wi-Fi APs and clients to files")
    func defaultSetup() {
        let setup = SurveySetup.read(.inMemory(), registered: false)
        #expect(setup.protocols == [.wifiAP, .wifiClient])
        #expect(setup.activeDestinations == [.logFiles])
        #expect(setup.sentence == "Will save Wi-Fi access points and clients to files on this iPhone.")
        #expect(setup.warnings.isEmpty)
    }

    @Test("A destination needs its settings before it counts")
    func configuredDestinations() {
        let settings = SettingsStore.inMemory()
        settings[Settings.destinationMQTT] = true
        settings[Settings.destinationNSAnalytics] = true
        var setup = SurveySetup.read(settings, registered: false)
        #expect(setup.activeDestinations == [.logFiles])
        settings[Settings.mqttHost] = "broker.example.com"
        settings[Settings.nsAnalyticsWorkspaceName] = "Field team"
        setup = SurveySetup.read(settings, registered: true)
        #expect(setup.activeDestinations == [.logFiles, .mqtt, .nsAnalytics])
        #expect(setup.details[.mqtt] == "broker.example.com:8883")
        #expect(setup.details[.nsAnalytics] == "Field team")
        #expect(setup.sentence == "Will record Wi-Fi access points and clients to files on this iPhone, your MQTT broker and NS Analytics.")
        // A demo board in use takes NS Analytics out of the survey.
        let demo = SurveySetup.read(settings, registered: true, demoBoardInUse: true)
        #expect(demo.activeDestinations == [.logFiles, .mqtt])
        #expect(demo.unavailable[.nsAnalytics] == "Not available with the demo board")
    }

    @Test("Raw frames without Files are flagged")
    func rawFramesWarning() {
        let settings = SettingsStore.inMemory()
        settings[Settings.surveyRawFrames] = true
        settings[Settings.destinationLogFiles] = false
        settings[Settings.destinationGRPC] = true
        settings[Settings.grpcHost] = "10.0.0.5"
        let setup = SurveySetup.read(settings, registered: false)
        #expect(setup.warnings == ["Raw frames are only saved to files, so they won't be kept. Turn on Files to keep them."])
        #expect(setup.sentence == "Will record Wi-Fi access points and clients to your gRPC server.")
    }

    @Test("Start is blocked by the worst problem first")
    func startBlocks() {
        let setup = SurveySetup.read(.inMemory(), registered: false)
        func block(_ ready: Int, real: Bool = false, setup: SurveySetup = setup, bluetooth: BluetoothAccess = .ready,
                   location: LocationAccess = .ready, incompatible: String? = nil) -> StartBlock? {
            StartBlock.evaluate(setup: setup, readyBoards: ready, realBoardsReady: real, incompatibleBoard: incompatible,
                                bluetooth: bluetooth, location: location)
        }
        #expect(block(0) == .noBoard)
        #expect(StartBlock.evaluate(setup: setup, readyBoards: 1, realBoardsReady: false, incompatibleBoard: nil,
                                    bluetooth: .ready, location: .notDetermined, storageAvailable: false) == .storageUnavailable)
        #expect(block(0, bluetooth: .off) == .bluetoothOff)
        #expect(block(0, bluetooth: .denied) == .bluetoothDenied)
        #expect(block(0, incompatible: "NS-1A2B") == .boardNeedsUpdate("NS-1A2B"))
        // The demo board works with Bluetooth off and without location access.
        #expect(block(1, bluetooth: .off, location: .denied) == nil)
        #expect(block(1, real: true, location: .denied) == .locationDenied)
        #expect(block(1, real: true, location: .servicesOff) == .locationServicesOff)
        #expect(block(1, real: true, location: .restricted) == .locationRestricted)
        #expect(block(1, real: true, location: .notDetermined) == nil)
        #expect(block(1, real: true, location: .approximate) == nil)
        var nothing = setup
        nothing.protocols = []
        #expect(block(1, setup: nothing) == .nothingToSurvey)
        var nowhere = setup
        nowhere.destinationsOn = []
        #expect(block(1, setup: nowhere) == .noDestination)
    }

    @Test("Live destination rows")
    func liveDestinations() {
        let csv = DestinationSnapshot(status: .running)
        var mqtt = DestinationSnapshot(status: .error("Connection refused"))
        mqtt.queueDepth = 120
        var ns = DestinationSnapshot(status: .running)
        ns.queueDepth = 40
        let snapshots = ["nsCSV": csv, "mqtt": mqtt, "nsAnalytics": ns]

        let files = LiveDestinationStatus.make(.logFiles, snapshots: snapshots, upload: nil)
        #expect(files.word == "Saving" && files.level == .good)
        #expect(files.detail == ["Files appear with the first record"])
        let failed = LiveDestinationStatus.make(.logFiles, snapshots: ["nsCSV": DestinationSnapshot(status: .error("Disk full"))], upload: nil)
        #expect(failed.word == "Not saving" && failed.level == .failing)

        let stream = LiveDestinationStatus.make(.mqtt, snapshots: snapshots, upload: nil)
        #expect(stream.word == "Can't connect" && stream.level == .failing)
        #expect(stream.detail == ["Connection refused", "120 waiting to send"])

        let upload = LiveDestinationStatus.make(.nsAnalytics, snapshots: snapshots, upload: nil)
        #expect(upload.word == "Queued" && upload.offersUpload)
        let done = LiveDestinationStatus.make(
            .nsAnalytics, snapshots: ["nsAnalytics": DestinationSnapshot(status: .running)], upload: nil, uploadIntervalMinutes: 0
        )
        #expect(done.word == "Up to date" && done.detail == ["Uploads when the survey stops"])
    }

    @Test("Board battery from cell voltage")
    func battery() {
        #expect(BoardBattery.percent(millivolts: 4200) == 100)
        #expect(BoardBattery.percent(millivolts: 4300) == 100)
        #expect(BoardBattery.percent(millivolts: 3800) == 50)
        #expect(BoardBattery.percent(millivolts: 3300) == 0)
        #expect(BoardBattery.percent(millivolts: 3000) == 0)
        #expect(BoardBattery.percent(millivolts: 3650) == 18)
    }

    @Test("Board roles are kept across launches")
    func roleStore() throws {
        let defaults = try #require(UserDefaults(suiteName: "role-store-test"))
        defaults.removePersistentDomain(forName: "role-store-test")
        let store = BoardRoleStore(defaults: defaults)
        let board = BoardID(UUID())
        store.save(.fixedChannel(11), for: board)
        #expect(store.load()[board] == .fixedChannel(11))
        store.save(.auto, for: board)
        #expect(store.load()[board] == nil)
    }

    @Test("The combined transport hides the demo board until it is turned on")
    func combinedTransport() async throws {
        let demo = SimulatedBoardTransport(boardCount: 1, seed: 1, timeSource: .manual)
        let transport = CombinedBoardTransport(demo: demo, demoEnabled: false)
        let board = try #require(demo.profiles.first?.id)
        var lists = transport.discoveries().makeAsyncIterator()
        #expect(await lists.next() == [])

        await transport.startScanning()
        await #expect(throws: BoardTransportError.unknownBoard) { try await transport.connect(board, timeout: nil) }
        await transport.setDemoEnabled(true)
        var found: [DiscoveredBoard] = []
        while found.isEmpty, let next = await lists.next() { found = next }
        #expect(found.map(\.id) == [board])

        try await transport.connect(board, timeout: nil)
        #expect(await transport.connectionStates()[board]?.isConnected == true)
        // Real boards need the Bluetooth transport, which is not set up here.
        await #expect(throws: BoardTransportError.bluetoothUnavailable("Bluetooth is not set up yet")) {
            try await transport.connect(BoardID(UUID()), timeout: nil)
        }
        await demo.shutdown()
    }
}
