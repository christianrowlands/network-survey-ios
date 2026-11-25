import Foundation
import SurveyCore
import Testing
@testable import NetworkSurvey

@MainActor
@Suite("Watchlist in the app", .serialized)
struct WatchlistAppTests {
    private func waitUntil(timeout: Duration = .seconds(20), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await condition()
    }

    @Test("A network added during a demo survey is marked and its sighting recorded")
    func demoSurveySighting() async throws {
        let store = try SurveyStore.inMemory()
        var options = LaunchOptions()
        options.uiTesting = true
        let model = AppModel(options: options, sharedStore: store)
        model.watchlist.notifier.asksForPermission = false
        await model.watchlistMonitor.start()
        let board = try #require(model.demoTransport.profiles.first?.id)
        #expect(await model.connect(board) == nil)
        await model.startSurvey()
        let sessionID = try #require(model.survey.session?.id)

        var heard: AccessPointRow?
        #expect(await waitUntil {
            heard = try? await store.read { db in
                try StoreQueries.accessPoints(db, sessionID: sessionID).first { $0.ssid?.isEmpty == false }
            }
            return heard != nil
        })
        let ap = try #require(heard)
        #expect(!model.settings[Settings.watchlistEnabled])
        let outcome = await model.watchlist.add(label: "", ssid: ap.ssid, bssid: nil, turnOnAlerts: true)
        #expect(outcome == .added(label: ap.ssid ?? "", alertsTurnedOn: true))
        #expect(model.settings[Settings.watchlistEnabled])
        #expect(await waitUntil { model.watchlist.isWatched(ssid: ap.ssid, bssid: ap.bssid) })
        // The same network again, in other case, is refused.
        let again = await model.watchlist.add(label: "Again", ssid: ap.ssid?.uppercased(), bssid: nil, turnOnAlerts: true)
        #expect(again == .duplicate)

        #expect(await waitUntil {
            let hits = (try? await store.read { try WatchlistQueries.hits($0) }) ?? []
            return hits.contains { $0.missionId == model.survey.missionId }
        }, "the demo Scout keeps hearing the network, so a sighting is recorded")
        #expect(await waitUntil { model.watchlist.summaries.first?.sightings == 1 })
        let missionID = model.survey.missionId
        #expect(model.finishedSurvey == nil)
        await model.stopSurvey()
        // Files are on by default, so Survey offers them to share.
        #expect(model.finishedSurvey?.missionId == missionID)
    }

    @Test("A watchlist share link opens the Watchlist to import it; other links go where they did")
    func linkRouting() throws {
        var options = LaunchOptions()
        options.uiTesting = true
        let model = AppModel(options: options, sharedStore: try SurveyStore.inMemory())
        let link = try #require(URL(string: "https://networksurvey.app/app/watchlist?d=eyJ2IjoxfQ"))
        model.handleOpenURL(link)
        #expect(model.pendingWatchlistLink == link)
        #expect(model.selectedTab == .tools && model.toolsRoute == .watchlist)
        let register = try #require(URL(string: "https://networksurvey.app/app/register?token=x"))
        model.handleOpenURL(register)
        #expect(model.pendingRegistrationLink == register && model.pendingWatchlistLink == link)
    }

    @Test("A sighting notification opens over the current tab")
    func sightingOpensOverCurrentTab() {
        var options = LaunchOptions()
        options.uiTesting = true
        let model = AppModel(options: options)
        model.selectedTab = .map
        model.showWatchlistSightings()
        #expect(model.selectedTab == .map && model.showingWatchlistHistory)
    }

    @Test("The notification names the network and its signal when known")
    func notificationText() {
        #expect(WatchlistNotifier.body(label: "ExampleNet", rssi: -58) == "ExampleNet is nearby (-58 dBm)")
        #expect(WatchlistNotifier.body(label: "Lobby AP", rssi: nil) == "Lobby AP is nearby")
    }

    @Test("History searches by name or address and sorts three ways")
    func historyArrangement() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func group(_ label: String, ssid: String?, bssid: String?, sightings: Int, last: TimeInterval, best: Int?) -> WatchlistHistoryGroup {
            WatchlistHistoryGroup(
                entry: WatchlistEntry(label: label, ssid: ssid, bssid: bssid, createdAt: t0),
                sightings: sightings, lastSeen: t0 + last, bestRssi: best
            )
        }
        let groups = [
            group("Cafe", ssid: "Cafe-Guest", bssid: nil, sightings: 5, last: 10, best: -70),
            group("Lobby AP", ssid: nil, bssid: "02:00:5e:00:53:01", sightings: 1, last: 30, best: -50),
            group("Home", ssid: "HomeNet", bssid: nil, sightings: 2, last: 20, best: nil),
        ]
        let names = { (list: [WatchlistHistoryGroup]) in list.map(\.entry.label) }
        #expect(names(WatchlistHistoryScreen.arrange(groups, search: "", sort: .recent)) == ["Lobby AP", "Home", "Cafe"])
        #expect(names(WatchlistHistoryScreen.arrange(groups, search: "", sort: .strongest)) == ["Lobby AP", "Cafe", "Home"])
        #expect(names(WatchlistHistoryScreen.arrange(groups, search: "", sort: .mostSeen)) == ["Cafe", "Home", "Lobby AP"])
        #expect(names(WatchlistHistoryScreen.arrange(groups, search: "homenet", sort: .recent)) == ["Home"])
        #expect(names(WatchlistHistoryScreen.arrange(groups, search: "53:01", sort: .recent)) == ["Lobby AP"])
    }
}
