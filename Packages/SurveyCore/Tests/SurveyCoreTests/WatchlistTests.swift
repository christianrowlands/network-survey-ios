import BoardKit
import BoardProtocol
import Foundation
import GRDB
import Testing
@testable import SurveyCore

@Suite("Watchlist matching")
struct WatchlistMatcherTests {
    func entry(ssid: String? = nil, bssid: String? = nil) -> WatchlistEntry {
        WatchlistEntry(id: 1, label: "Watched", ssid: ssid, bssid: bssid, createdAt: Fixtures.base)
    }

    @Test("An SSID entry matches that SSID on any access point, ignoring case")
    func ssidOnly() {
        let watched = entry(ssid: "ExampleNet")
        #expect(WatchlistMatcher.matches(watched, ssid: "ExampleNet", bssid: "02:00:5e:00:00:01"))
        #expect(WatchlistMatcher.matches(watched, ssid: "examplenet", bssid: "02:00:5e:00:00:02"))
        #expect(WatchlistMatcher.matches(watched, ssid: "EXAMPLENET", bssid: nil))
        #expect(!WatchlistMatcher.matches(watched, ssid: "ExampleNet-5G", bssid: "02:00:5e:00:00:01"))
        #expect(!WatchlistMatcher.matches(watched, ssid: "Example", bssid: "02:00:5e:00:00:01"))
    }

    @Test("A hidden network never matches an SSID")
    func hiddenNeverMatchesSSID() {
        #expect(!WatchlistMatcher.matches(entry(ssid: "ExampleNet"), ssid: "", bssid: "02:00:5e:00:00:01"))
        #expect(!WatchlistMatcher.matches(entry(ssid: "ExampleNet"), ssid: nil, bssid: "02:00:5e:00:00:01"))
        #expect(!WatchlistMatcher.matches(entry(ssid: "ExampleNet"), ssid: "   ", bssid: nil))
    }

    @Test("A BSSID entry matches that access point whatever its SSID, hidden included")
    func bssidOnly() {
        let watched = entry(bssid: "02:00:5e:00:00:01")
        #expect(WatchlistMatcher.matches(watched, ssid: "ExampleNet", bssid: "02:00:5E:00:00:01"))
        #expect(WatchlistMatcher.matches(watched, ssid: "", bssid: "02:00:5e:00:00:01"))
        #expect(WatchlistMatcher.matches(watched, ssid: nil, bssid: "02:00:5e:00:00:01"))
        #expect(!WatchlistMatcher.matches(watched, ssid: "ExampleNet", bssid: "02:00:5e:00:00:02"))
        #expect(!WatchlistMatcher.matches(watched, ssid: "ExampleNet", bssid: nil))
    }

    @Test("An entry with both needs both to match")
    func bothRequired() {
        let watched = entry(ssid: "ExampleNet", bssid: "02:00:5e:00:00:01")
        #expect(WatchlistMatcher.matches(watched, ssid: "examplenet", bssid: "02:00:5E:00:00:01"))
        #expect(!WatchlistMatcher.matches(watched, ssid: "ExampleNet", bssid: "02:00:5e:00:00:02"))
        #expect(!WatchlistMatcher.matches(watched, ssid: "OtherNet", bssid: "02:00:5e:00:00:01"))
        #expect(!WatchlistMatcher.matches(watched, ssid: "", bssid: "02:00:5e:00:00:01"))
    }

    @Test("Values are trimmed on both sides")
    func trimming() {
        #expect(WatchlistMatcher.matches(entry(ssid: "  ExampleNet "), ssid: "ExampleNet\n", bssid: nil))
        #expect(WatchlistMatcher.matches(entry(bssid: " 02:00:5e:00:00:01 "), ssid: nil, bssid: "02:00:5e:00:00:01 "))
    }

    @Test("An entry with no identifiers, or only blanks, never matches")
    func emptyEntry() {
        #expect(!WatchlistMatcher.matches(entry(), ssid: "ExampleNet", bssid: "02:00:5e:00:00:01"))
        #expect(!WatchlistMatcher.matches(entry(ssid: " ", bssid: ""), ssid: "", bssid: ""))
        #expect(!WatchlistMatcher.matches(entry(ssid: " ", bssid: ""), ssid: " ", bssid: ""))
    }

    @Test("Normalization, labels, duplicates and BSSID formats")
    func normalization() {
        #expect(WatchlistMatcher.normalizeSSID("  Cafe Guest ") == "Cafe Guest")
        #expect(WatchlistMatcher.normalizeSSID("   ") == nil)
        #expect(WatchlistMatcher.normalizeBSSID(" 02:00:5E:AA:BB:CC ") == "02:00:5e:aa:bb:cc")
        #expect(WatchlistMatcher.resolveLabel(" ", ssid: "ExampleNet", bssid: "02:00:5e:00:00:01") == "ExampleNet")
        #expect(WatchlistMatcher.resolveLabel(nil, ssid: nil, bssid: "02:00:5E:00:00:01") == "02:00:5e:00:00:01")
        #expect(WatchlistMatcher.resolveLabel("Lobby", ssid: "ExampleNet", bssid: nil) == "Lobby")
        #expect(WatchlistMatcher.dedupKey(ssid: "ExampleNet", bssid: nil) == WatchlistMatcher.dedupKey(ssid: " examplenet", bssid: ""))
        #expect(WatchlistMatcher.dedupKey(ssid: "ExampleNet", bssid: nil) != WatchlistMatcher.dedupKey(ssid: "ExampleNet", bssid: "02:00:5e:00:00:01"))
        // The length prefix keeps an SSID with a colon from looking like a BSSID.
        #expect(WatchlistMatcher.dedupKey(ssid: "a:b", bssid: nil) != WatchlistMatcher.dedupKey(ssid: "a", bssid: "b"))
        #expect(WatchlistMatcher.isValidBSSID("02:00:5E:aa:bb:cc"))
        #expect(!WatchlistMatcher.isValidBSSID("02-00-5E-aa-bb-cc"))
        #expect(!WatchlistMatcher.isValidBSSID("02:00:5E:aa:bb"))
        #expect(!WatchlistMatcher.isValidBSSID("02:00:5E:aa:bb:cg"))
        #expect(WatchlistMatcher.parseBSSID("02-00-5E-AA-BB-CC") == "02:00:5e:aa:bb:cc")
        #expect(WatchlistMatcher.parseBSSID("02005eaabbcc") == "02:00:5e:aa:bb:cc")
        #expect(WatchlistMatcher.parseBSSID("02:00:5e:aa:bb") == nil)
        #expect(WatchlistMatcher.parseBSSID("ExampleNet") == nil)
    }
}

@Suite("Watchlist alerts")
struct WatchlistDetectorTests {
    let t0 = Fixtures.base

    func detector(cooldown: Int = 900, enabled: Bool = true) -> WatchlistDetector {
        WatchlistDetector(entries: [
            WatchlistEntry(id: 1, label: "Example", ssid: "ExampleNet", bssid: nil, enabled: enabled, cooldownSeconds: cooldown, createdAt: t0),
            WatchlistEntry(id: 2, label: "Lobby AP", ssid: nil, bssid: "02:00:5e:00:00:02", cooldownSeconds: cooldown, createdAt: t0),
        ])
    }

    func see(_ d: inout WatchlistDetector, _ ssid: String = "ExampleNet", _ bssid: String = "02:00:5e:00:00:01",
             at offset: TimeInterval, lag: TimeInterval = 0) -> [Int64] {
        d.observe(ssid: ssid, bssid: bssid, at: t0 + offset, receivedAt: t0 + offset + lag).compactMap(\.id)
    }

    @Test("Alerts on the first sighting, not again while the network stays")
    func firstSightingOnly() {
        var d = detector()
        #expect(see(&d, at: 0) == [1])
        #expect(see(&d, at: 1).isEmpty)
        #expect(see(&d, at: 50).isEmpty)
        // Seen every 50 s: never absent for the 60 s window, so never again.
        #expect(see(&d, at: 100).isEmpty)
        #expect(see(&d, at: 150).isEmpty)
        // Gone for half an hour: past both the absence window and the cooldown.
        #expect(see(&d, at: 2000) == [1])
    }

    @Test("A network that was gone for the absence window alerts again after the cooldown")
    func absenceAndCooldown() {
        var d = detector(cooldown: 900)
        #expect(see(&d, at: 0) == [1])
        // Gone for over 60 s but within the cooldown: no alert.
        #expect(see(&d, at: 120).isEmpty)
        // Gone again for over 60 s, past the cooldown: alert.
        #expect(see(&d, at: 1000) == [1])
        // A dropped scan or two (under 60 s) is not absence.
        #expect(see(&d, at: 1050).isEmpty)
    }

    @Test("A short cooldown alerts on every reappearance after the absence window")
    func shortCooldown() {
        var d = detector(cooldown: 0)
        #expect(see(&d, at: 0) == [1])
        #expect(see(&d, at: 59).isEmpty)
        #expect(see(&d, at: 118).isEmpty)
        #expect(see(&d, at: 180) == [1])
    }

    @Test("Each entry has its own presence; one record can alert several entries")
    func perEntry() {
        var d = detector()
        #expect(see(&d, "ExampleNet", "02:00:5e:00:00:02", at: 0).sorted() == [1, 2])
        #expect(see(&d, "OtherNet", "02:00:5e:00:00:02", at: 1).isEmpty)
    }

    @Test("Late records from a Scout catching up never alert")
    func lateRecords() {
        var d = detector()
        #expect(see(&d, at: 0, lag: 30).isEmpty)
        #expect(see(&d, at: 1, lag: 5) == [1])
    }

    @Test("Disabled entries are not watched, and edits keep presence")
    func entriesChange() {
        var d = detector(enabled: false)
        #expect(see(&d, at: 0).isEmpty)
        d.setEntries([WatchlistEntry(id: 1, label: "Example", ssid: "ExampleNet", bssid: nil, createdAt: t0)])
        #expect(see(&d, at: 1) == [1])
        d.setEntries([
            WatchlistEntry(id: 1, label: "Renamed", ssid: "ExampleNet", bssid: nil, createdAt: t0),
            WatchlistEntry(id: 3, label: "New", ssid: "OtherNet", bssid: nil, createdAt: t0),
        ])
        #expect(see(&d, at: 2).isEmpty)
        // A removed entry loses its presence: added back, it alerts again.
        d.setEntries([])
        d.setEntries([WatchlistEntry(id: 1, label: "Example", ssid: "ExampleNet", bssid: nil, cooldownSeconds: 0, createdAt: t0)])
        #expect(see(&d, at: 3) == [1])
    }
}

@Suite("Watchlist store")
struct WatchlistStoreTests {
    let t0 = Fixtures.base

    @Test("Adding normalizes, resolves the label and refuses duplicates")
    func add() async throws {
        let store = try SurveyStore.inMemory()
        guard case .saved(let first) = try await store.addWatchlistEntry(label: " ", ssid: " ExampleNet ", bssid: nil, now: t0)
        else { Issue.record("not added"); return }
        #expect(first.label == "ExampleNet" && first.ssid == "ExampleNet" && first.bssid == nil && first.id != nil)
        #expect(first.matchType == "EXACT" && first.enabled && first.cooldownSeconds == 900)
        #expect(first.createdAt == t0 && first.updatedAt == t0 && UUID(uuidString: first.uuid) != nil)
        #expect(try await store.addWatchlistEntry(label: "Other", ssid: "examplenet", bssid: nil) == .duplicate)
        #expect(try await store.addWatchlistEntry(label: nil, ssid: "  ", bssid: nil) == .invalid)
        guard case .saved(let second) = try await store.addWatchlistEntry(label: nil, ssid: "ExampleNet", bssid: "02:00:5E:00:00:01")
        else { Issue.record("an SSID plus BSSID entry is a different network"); return }
        #expect(second.bssid == "02:00:5e:00:00:01" && second.label == "ExampleNet")
        #expect(try await store.watchlistEntries().count == 2)
    }

    @Test("Editing keeps the UUID and sightings; delete removes both")
    func editAndDelete() async throws {
        let store = try SurveyStore.inMemory()
        guard case .saved(let entry) = try await store.addWatchlistEntry(label: "Cafe", ssid: "Cafe-Guest", bssid: nil, now: t0),
              case .saved(let other) = try await store.addWatchlistEntry(label: nil, ssid: nil, bssid: "02:00:5e:00:00:09", now: t0),
              let id = entry.id, let otherID = other.id
        else { Issue.record("not added"); return }
        try await store.insertWatchlistHit(hit(entryID: id, at: 10))
        let edited = try await store.updateWatchlistEntry(id: id, label: "Corner cafe", ssid: "Cafe-Guest", bssid: "02:00:5E:00:00:01", now: t0 + 60)
        guard case .saved(let updated) = edited else { Issue.record("not saved"); return }
        #expect(updated.uuid == entry.uuid && updated.label == "Corner cafe" && updated.bssid == "02:00:5e:00:00:01")
        #expect(updated.createdAt == t0 && updated.updatedAt == t0 + 60)
        #expect(try await store.updateWatchlistEntry(id: id, label: nil, ssid: nil, bssid: "02:00:5e:00:00:09") == .duplicate)
        try await store.setWatchlistEntry(id: id, enabled: false)
        #expect(try await store.watchlistEntries().first { $0.id == id }?.enabled == false)
        let summaries = try await store.read(WatchlistQueries.summaries)
        #expect(summaries.first { $0.entry.id == id }?.sightings == 1)
        #expect(summaries.first { $0.entry.id == otherID }?.sightings == 0)
        try await store.deleteWatchlistEntry(id: id)
        #expect(try await store.read { try WatchlistQueries.hits($0) }.isEmpty)
        #expect(try await store.watchlistEntries().map(\.id) == [otherID])
        try await store.clearWatchlist()
        #expect(try await store.watchlistEntries().isEmpty)
    }

    @Test("History groups, per-entry sightings, clearing and the 90 day retention")
    func history() async throws {
        let store = try SurveyStore.inMemory()
        guard case .saved(let a) = try await store.addWatchlistEntry(label: "A", ssid: "ExampleNet", bssid: nil),
              case .saved(let b) = try await store.addWatchlistEntry(label: "B", ssid: "HomeNet", bssid: nil),
              let idA = a.id, let idB = b.id
        else { Issue.record("not added"); return }
        try await store.insertWatchlistHit(hit(entryID: idA, at: 0, rssi: -70, located: true))
        try await store.insertWatchlistHit(hit(entryID: idA, at: 100, rssi: nil))
        try await store.insertWatchlistHit(hit(entryID: idB, at: 50, rssi: -50))
        let groups = try await store.read(WatchlistQueries.historyGroups)
        #expect(groups.map(\.entry.label) == ["A", "B"])
        #expect(groups[0].sightings == 2 && groups[0].bestRssi == -70 && groups[0].lastSeen == t0 + 100)
        let hits = try await store.read { try WatchlistQueries.hits($0, entryID: idA) }
        #expect(hits.map(\.timestamp) == [t0 + 100, t0])
        #expect(hits[1].hasLocation && !hits[0].hasLocation && hits[0].rssi == nil)
        let summary = try await store.read(WatchlistQueries.summaries).first { $0.entry.id == idA }
        #expect(summary?.lastSeen == t0 + 100 && summary?.lastRssi == nil)
        #expect(try await store.pruneWatchlistHits(before: t0 + 60) == 2)
        try await store.clearWatchlistHistory(entryID: idB)
        #expect(try await store.read(WatchlistQueries.historyGroups).map(\.entry.label) == ["A"])
        try await store.clearWatchlistHistory()
        #expect(try await store.read(WatchlistQueries.historyGroups).isEmpty)
        #expect(try await store.watchlistEntries().count == 2)
        // A sighting for an entry removed meanwhile is not stored.
        #expect(try await store.insertWatchlistHit(hit(entryID: 999, at: 0)) == nil)
    }

    @Test("Networks seen counts each watched network once per survey")
    func networksSeen() async throws {
        let store = try SurveyStore.inMemory()
        guard case .saved(let a) = try await store.addWatchlistEntry(label: "A", ssid: "ExampleNet", bssid: nil),
              case .saved(let b) = try await store.addWatchlistEntry(label: "B", ssid: "HomeNet", bssid: nil),
              let idA = a.id, let idB = b.id
        else { Issue.record("not added"); return }
        try await store.insertWatchlistHit(hit(entryID: idA, at: 0))
        try await store.insertWatchlistHit(hit(entryID: idA, at: 10))
        try await store.insertWatchlistHit(hit(entryID: idB, at: 20, mission: "M2"))
        #expect(try await store.read { try WatchlistQueries.networksSeen($0, missionID: "M1") } == 1)
        #expect(try await store.read { try WatchlistQueries.networksSeen($0, missionID: "M2") } == 1)
        #expect(try await store.read { try WatchlistQueries.networksSeen($0, missionID: "M3") } == 0)
    }

    func hit(
        entryID: Int64, at offset: TimeInterval, rssi: Int? = -60, located: Bool = false, mission: String = "M1"
    ) -> WatchlistHit {
        WatchlistHit(
            entryId: entryID, label: "X", matchedField: .ssid, ssid: "ExampleNet", bssid: "02:00:5e:00:00:01", rssi: rssi,
            latitude: located ? 38.89 : nil, longitude: located ? -77.03 : nil, timestamp: t0 + offset, missionId: mission
        )
    }
}

@Suite("Watchlist during a survey")
struct WatchlistPipelineTests {
    let board = BoardID(UUID(uuidString: "00000000-0000-4000-8000-00000000000A")!)

    @Test("A watched access point is stored as a sighting and announced once")
    func sightingFromPipeline() async throws {
        let store = try SurveyStore.inMemory()
        try await store.insertSession(Fixtures.sessionRow())
        let settings = SettingsStore.inMemory()
        settings[Settings.watchlistEnabled] = true
        _ = try await store.addWatchlistEntry(label: "Watched", ssid: "ExampleNet", bssid: nil)
        let monitor = WatchlistMonitor(store: store, settings: settings)
        await monitor.refresh()
        let sightings = monitor.sightings()
        let zone = PrivacyZone(name: "Home", center: GeoPoint(latitude: 10, longitude: 10), radiusMeters: 100)
        let pipeline = RecordPipeline(
            session: Fixtures.context(), store: store, sinks: [], privacy: PrivacyFilter(zones: [zone]),
            policy: LocationSourcePolicy(), watchlist: monitor, now: { Fixtures.base }
        )
        await pipeline.ingestPhoneLocation(Fixtures.phoneFix(latitude: 38.89, time: Fixtures.base))
        await pipeline.ingest(Fixtures.batch([
            Fixtures.ap("02:00:5E:00:00:01", ssid: "ExampleNet", rssi: -55),
            Fixtures.ap("02:00:5E:00:00:02", ssid: "ExampleNet", rssi: -65),
            Fixtures.ap("02:00:5E:00:00:03", ssid: "OtherNet"),
        ]), from: board)
        var iterator = sightings.makeAsyncIterator()
        let sighting = await iterator.next()
        #expect(sighting?.hit.id != nil)
        #expect(sighting?.hit.bssid == "02:00:5e:00:00:01" && sighting?.hit.rssi == -55)
        #expect(sighting?.hit.latitude == 38.89 && sighting?.hit.missionId == Fixtures.context().missionId)
        #expect(sighting?.entry.label == "Watched" && sighting?.location?.latitude == 38.89)
        let stored = try await store.read { try WatchlistQueries.hits($0) }
        #expect(stored.count == 1)

        // Inside a privacy zone the record is dropped, but a sighting is kept without a location.
        _ = try await store.addWatchlistEntry(label: nil, ssid: nil, bssid: "02:00:5e:00:00:07")
        await monitor.refresh()
        await pipeline.ingestPhoneLocation(Fixtures.phoneFix(latitude: 10, longitude: 10, time: Fixtures.base + 1))
        await pipeline.ingest(Fixtures.batch([Fixtures.ap("02:00:5E:00:00:07", ssid: "", time: Fixtures.base + 1)], receivedAt: Fixtures.base + 1), from: board)
        let inZone = await iterator.next()
        #expect(inZone?.hit.latitude == nil && inZone?.location == nil && inZone?.hit.matchedField == .bssid)
        await pipeline.flush()
        let aps = try await store.read { try StoreQueries.counts($0, sessionID: "S1").accessPoints }
        #expect(aps == 3)
    }

    @Test("Nothing is watched while the watchlist setting is off")
    func settingOff() async throws {
        let store = try SurveyStore.inMemory()
        let settings = SettingsStore.inMemory()
        _ = try await store.addWatchlistEntry(label: nil, ssid: "ExampleNet", bssid: nil)
        let monitor = WatchlistMonitor(store: store, settings: settings)
        await monitor.start(now: Fixtures.base)
        var ap = NSBApObservation()
        ap.bssid = Fixtures.mac("02:00:5E:00:00:01")
        ap.ssid = Data("ExampleNet".utf8)
        monitor.observe(ap, time: Fixtures.base, receivedAt: Fixtures.base, location: nil, missionId: "M")
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await store.read { try WatchlistQueries.hits($0) }.isEmpty)
        // Turning it on applies at once.
        settings[Settings.watchlistEnabled] = true
        let sightings = monitor.sightings()
        #expect(await waitUntil {
            monitor.observe(ap, time: Fixtures.base, receivedAt: Fixtures.base, location: nil, missionId: "M")
            return (try? await store.read { try WatchlistQueries.hits($0) }.count) == 1
        })
        var iterator = sightings.makeAsyncIterator()
        #expect(await iterator.next()?.hit.ssid == "ExampleNet")
    }
}
