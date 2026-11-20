import BoardProtocol
import Destinations
import Foundation
import NSMessaging
import Synchronization
import Testing
@testable import SurveyCore

@Suite("Watchlist share links")
struct WatchlistLinkTests {
    /// The worked example on networksurvey.app's watchlist link page, the
    /// format the Network Survey Android app opens.
    static let androidExample = URL(string: "https://networksurvey.app/app/watchlist?d=eyJ2IjoxLCJuYW1lIjoiQWNtZSBuZXR3b3JrcyIsImVudHJpZXMiOlt7ImxhYmVsIjoiSFEiLCJzc2lkIjoiSFEtR3Vlc3QifSx7ImxhYmVsIjoiTG9iYnkiLCJic3NpZCI6ImE0OjExOjIyOjMzOjQ0OjFjIn1dfQ")!

    func link(_ json: String) -> URL {
        URL(string: "https://networksurvey.app/app/watchlist?d=" + WatchlistLink.encodeBase64URL(Data(json.utf8)))!
    }

    func parse(_ json: String) -> Result<WatchlistImportSet, WatchlistLinkError> {
        Result { () throws(WatchlistLinkError) in try WatchlistLink.parse(link(json)) }
    }

    @Test("Reads the Android example link")
    func androidExample() throws {
        #expect(WatchlistLink.isWatchlistLink(Self.androidExample))
        let set = try WatchlistLink.parse(Self.androidExample)
        #expect(set.name == "Acme networks")
        #expect(set.entries == [
            WatchlistImportEntry(label: "HQ", ssid: "HQ-Guest", bssid: nil),
            WatchlistImportEntry(label: "Lobby", ssid: nil, bssid: "a4:11:22:33:44:1c"),
        ])
    }

    @Test("Builds the same link as the documented example")
    func makesTheDocumentedLink() throws {
        let t0 = Fixtures.base
        let url = try WatchlistLink.makeURL(name: "Acme networks", entries: [
            WatchlistEntry(label: "HQ", ssid: "HQ-Guest", bssid: nil, createdAt: t0),
            WatchlistEntry(label: "Lobby", ssid: nil, bssid: "a4:11:22:33:44:1c", createdAt: t0),
        ])
        #expect(url == Self.androidExample)
        // A label that is just the network name or address is left out.
        let plain = try WatchlistLink.makeURL(entries: [WatchlistEntry(label: "ExampleNet", ssid: "ExampleNet", bssid: nil, createdAt: t0)])
        #expect(plain == link(#"{"v":1,"entries":[{"ssid":"ExampleNet"}]}"#))
        #expect(try WatchlistLink.parse(plain).entries == [WatchlistImportEntry(label: nil, ssid: "ExampleNet", bssid: nil)])
        let many = (0...WatchlistLimits.maxEntries).map { WatchlistEntry(label: "n\($0)", ssid: "Net\($0)", bssid: nil, createdAt: t0) }
        #expect(throws: WatchlistLinkError.tooMany) { try WatchlistLink.makeURL(entries: many) }
    }

    @Test("Normalizes like Android: BSSID lowercase, SSID case kept, missing name, cleaned text")
    func normalization() throws {
        let set = try parse(#"{"v":1,"entries":[{"ssid":"MyNetwork","bssid":"A4:B5:C6:D7:E8:F9"}]}"#).get()
        #expect(set.name == nil && set.entries == [WatchlistImportEntry(label: nil, ssid: "MyNetwork", bssid: "a4:b5:c6:d7:e8:f9")])
        let cleaned = try parse("{\"v\":1,\"name\":\"Ac\\u0007me\\u200B \\u202E\",\"entries\":[{\"label\":\"H\\u001bQ\",\"ssid\":\" HQ \"}]}").get()
        #expect(cleaned.name == "Acme" && cleaned.entries.first?.label == "HQ" && cleaned.entries.first?.ssid == "HQ")
        // Entries with nothing to match, and JSON nulls, are skipped.
        #expect(try parse(#"{"v":1,"entries":[{"label":"empty"},{"ssid":"Keep"},null]}"#).get().entries.map(\.ssid) == ["Keep"])
        #expect(WatchlistLink.find(in: "Watch these: \(Self.androidExample.absoluteString) thanks") == Self.androidExample)
        #expect(WatchlistLink.find(in: "https://networksurvey.app/app/register?x=1") == nil)
    }

    @Test("Refuses the whole link for anything out of bounds")
    func errors() {
        func error(_ url: URL) -> WatchlistLinkError? {
            do { _ = try WatchlistLink.parse(url) } catch { return error }
            return nil
        }
        func error(_ json: String) -> WatchlistLinkError? { error(link(json)) }
        let base = "https://networksurvey.app/app/watchlist"
        #expect(error(URL(string: base)!) == .noData)
        #expect(error(URL(string: base + "?d=")!) == .noData)
        #expect(error(URL(string: base + "?d=" + String(repeating: "A", count: 16_385))!) == .tooLarge)
        #expect(error(URL(string: base + "?d=%25%25%25")!) == .unreadable)
        #expect(error(URL(string: base + "?d=" + Data("not json".utf8).base64EncodedString())!) == .unreadable)
        // Standard base64 with + or / is not read, as on Android.
        #expect(error(URL(string: base + "?d=eyJ2IjoxfQ+/")!) == .unreadable)
        #expect(error(#"{"v":2,"entries":[{"ssid":"HQ"}]}"#) == .newerVersion)
        #expect(error(#"{"entries":[{"ssid":"HQ"}]}"#) == .newerVersion)
        #expect(error(#"{"v":1,"entries":[]}"#) == .noNetworks)
        #expect(error(#"{"v":1}"#) == .noNetworks)
        #expect(error(#"{"v":1,"entries":[null,null]}"#) == .noValidNetworks)
        #expect(error(#"{"v":1,"entries":[{"label":"a"},{"label":"b"}]}"#) == .noValidNetworks)
        let tooMany = (0...100).map { #"{"ssid":"net\#($0)"}"# }.joined(separator: ",")
        #expect(error(#"{"v":1,"entries":[\#(tooMany)]}"#) == .tooMany)
        #expect(error(#"{"v":1,"entries":[{"ssid":"Keep"},{"bssid":"not-a-mac"}]}"#) == .invalidBSSID)
        #expect(error(#"{"v":1,"entries":[{"ssid":"\#(String(repeating: "s", count: 33))"}]}"#) == .ssidTooLong)
        #expect(error(#"{"v":1,"entries":[{"label":"\#(String(repeating: "l", count: 101))","ssid":"HQ"}]}"#) == .labelTooLong)
        #expect(error(#"{"v":1,"name":"\#(String(repeating: "n", count: 101))","entries":[{"ssid":"HQ"}]}"#) == .nameTooLong)
        // Other links are not watchlist links.
        #expect(!WatchlistLink.isWatchlistLink(URL(string: "https://networksurvey.app/app/register?d=x")!))
        #expect(!WatchlistLink.isWatchlistLink(URL(string: "https://example.com/app/watchlist?d=x")!))
    }
}

@Suite("Watchlist import")
struct WatchlistImportTests {
    @Test("Plans against the watchlist and within the link, then adds only the new networks")
    func planAndImport() async throws {
        let store = try SurveyStore.inMemory()
        _ = try await store.addWatchlistEntry(label: "Mine", ssid: "HQ-Guest", bssid: nil)
        let set = WatchlistImportSet(name: "Acme", entries: [
            WatchlistImportEntry(label: nil, ssid: "hq-guest", bssid: nil),
            WatchlistImportEntry(label: "Lobby", ssid: nil, bssid: "a4:11:22:33:44:1c"),
            WatchlistImportEntry(label: "Lobby again", ssid: nil, bssid: "A4:11:22:33:44:1C"),
            WatchlistImportEntry(label: nil, ssid: "HQ-Guest", bssid: "a4:11:22:33:44:1c"),
        ])
        let plan = WatchlistImportPlanner.plan(existing: try await store.watchlistEntries(), set: set)
        #expect(plan.rows.map(\.isDuplicate) == [true, false, true, false])
        #expect(plan.rows.map(\.label) == ["hq-guest", "Lobby", "Lobby again", "HQ-Guest"])
        #expect(plan.addedCount == 2 && plan.duplicateCount == 2)
        let result = try await store.importWatchlist(set)
        #expect(result.added == 2 && result.skipped == 2)
        let entries = try await store.watchlistEntries()
        #expect(entries.count == 3)
        #expect(entries.first { $0.label == "Mine" }?.ssid == "HQ-Guest", "existing entries are never changed")
        #expect(try await store.importWatchlist(set).added == 0)
    }
}

/// A sink that streams the watchlist, like the MQTT destination.
final class WatchlistSink: SurveyRecordSink {
    let name = "watchlist"
    let messages = Mutex<[WatchlistMessage]>([])
    let handler = Mutex<(@Sendable () -> Void)?>(nil)

    func start(_ session: SessionContext) async throws {}
    func accept(_ records: [SurveyOutput]) async {}
    func stop() async {}
    func snapshots() async -> [String: DestinationSnapshot] { [:] }
    var streamsWatchlist: Bool { true }
    func acceptWatchlist(_ message: WatchlistMessage) async { messages.withLock { $0.append(message) } }
    func onWatchlistConnected(_ handler: @escaping @Sendable () -> Void) async { self.handler.withLock { $0 = handler } }

    func connect() { handler.withLock { $0 }?() }
    var updates: [WatchlistEntryUpdate] {
        messages.withLock { $0 }.compactMap { if case .entries(let update) = $0 { update } else { nil } }
    }
    var matches: [WatchlistMatch] {
        messages.withLock { $0 }.compactMap { if case .match(let match) = $0 { match } else { nil } }
    }
}

@Suite("Watchlist over MQTT", .serialized)
struct WatchlistStreamingTests {
    let now: @Sendable () -> Date = { Fixtures.base }

    @Test("A never-used watchlist sends nothing; then snapshots on connect and on change, sequence from the clock then +1")
    func snapshots() async throws {
        let store = try SurveyStore.inMemory()
        let settings = SettingsStore.inMemory()
        let sink = WatchlistSink()
        let tasks = await WatchlistStreaming.start(
            sinks: [RecordingSink(), sink], store: store, settings: settings, monitor: nil, session: Fixtures.context(), now: now
        )
        defer { tasks.forEach { $0.cancel() } }
        sink.connect()
        try await Task.sleep(for: .milliseconds(200))
        #expect(sink.updates.isEmpty, "a device that never had an entry sends nothing")

        _ = try await store.addWatchlistEntry(label: "Lobby AP", ssid: nil, bssid: "02:00:5E:00:53:01", now: Fixtures.base)
        #expect(await waitUntil { sink.updates.count == 1 })
        let first = try #require(sink.updates.first)
        #expect(first.data.messageSequence == UInt64(Fixtures.base.timeIntervalSince1970 * 1000))
        #expect(first.data.changeType == .snapshot && first.data.missionId == Fixtures.context().missionId)
        let entry = try #require(first.data.entries.first)
        #expect(entry.label == "Lobby AP" && entry.ssid == nil && entry.bssid == "02:00:5e:00:53:01")
        #expect(entry.enabled == true && entry.matchType == .exact && entry.cooldownSeconds == 900)
        #expect(entry.createdAt == DeviceTime.string(Fixtures.base, timeZone: .current))

        sink.connect()
        #expect(await waitUntil { sink.updates.count == 2 })
        #expect(sink.updates[1].data.messageSequence == first.data.messageSequence + 1)

        // Clearing the list still sends an (empty) snapshot once one was sent.
        try await store.clearWatchlist()
        #expect(await waitUntil { sink.updates.count == 3 })
        #expect(sink.updates[2].data.entries.isEmpty && sink.updates[2].data.messageSequence == first.data.messageSequence + 2)
        #expect(settings[Settings.watchlistMessageSequence] == Int(first.data.messageSequence) + 2)

        // Turned off, nothing is sent; turned back on, a snapshot goes out.
        settings[Settings.watchlistStreamMQTT] = false
        sink.connect()
        try await Task.sleep(for: .milliseconds(200))
        #expect(sink.updates.count == 3)
        settings[Settings.watchlistStreamMQTT] = true
        #expect(await waitUntil { sink.updates.count == 4 })
    }

    @Test("A sighting becomes a WatchlistMatch with the record's location and signal")
    func match() async throws {
        let store = try SurveyStore.inMemory()
        let settings = SettingsStore.inMemory()
        settings[Settings.watchlistEnabled] = true
        guard case .saved(let entry) = try await store.addWatchlistEntry(label: "Watched", ssid: "ExampleNet", bssid: nil)
        else { Issue.record("not added"); return }
        let monitor = WatchlistMonitor(store: store, settings: settings)
        await monitor.refresh()
        let sink = WatchlistSink()
        let tasks = await WatchlistStreaming.start(
            sinks: [sink], store: store, settings: settings, monitor: monitor, session: Fixtures.context(), now: now
        )
        defer { tasks.forEach { $0.cancel() } }
        var ap = NSBApObservation()
        ap.bssid = Fixtures.mac("02:00:5E:00:00:01")
        ap.ssid = Data("ExampleNet".utf8)
        ap.rssiLast = -58
        let fix = LocationSample(latitude: 38.889484, longitude: -77.035278, altitude: 21.3, horizontalAccuracy: 5,
                                 speed: 1.5, timestamp: Fixtures.base - 2, source: .phone)
        monitor.observe(ap, time: Fixtures.base, receivedAt: Fixtures.base, location: fix, missionId: "NS TEST 1")
        #expect(await waitUntil { sink.matches.count == 1 })
        let data = try #require(sink.matches.first?.data)
        #expect(data.entryUuid == entry.uuid && data.label == "Watched" && data.matchType == .exact && data.matchedField == .ssid)
        #expect(data.ssid == "ExampleNet" && data.bssid == "02:00:5e:00:00:01" && data.signalStrength == -58)
        #expect(data.recordNumber == 1 && data.missionId == "NS TEST 1")
        #expect(data.latitude == 38.889484 && data.longitude == -77.035278 && data.accuracy == 5 && data.locationAge == 2000)
        #expect(data.deviceSerialNumber == Fixtures.installID.uuidString)
        let json = try #require(sink.matches.first).jsonString()
        #expect(json.contains(#""messageType":"WatchlistMatch""#) && json.contains(#""signalStrength":-58"#))
    }

    @Test("Sinks that do not stream the watchlist get nothing and start no tasks")
    func noStreamingSink() async throws {
        let tasks = await WatchlistStreaming.start(
            sinks: [RecordingSink()], store: try SurveyStore.inMemory(), settings: SettingsStore.inMemory(), monitor: nil,
            session: Fixtures.context(), now: now
        )
        #expect(tasks.isEmpty)
    }
}
