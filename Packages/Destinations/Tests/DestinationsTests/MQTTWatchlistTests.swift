import Foundation
import NSMessaging
import Synchronization
import Testing
@testable import Destinations

#if os(macOS)
@Suite("MQTT watchlist messages", .serialized, .enabled(if: LocalBroker.available))
struct MQTTWatchlistTests {
    @Test("Matches and entry snapshots go to the Android topics, stamped, and the connect handler fires")
    func topics() async throws {
        let broker = try LocalBroker()
        try await broker.start()
        defer { broker.stop() }
        let subscriber = try await Subscriber(port: broker.port)
        let destination = MQTTDestination(config: MQTTConfig(
            host: "127.0.0.1", port: broker.port, useTLS: false, clientID: "ns-test-w", topicPrefix: "site-a/"
        ))
        let connects = Mutex(0)
        try await destination.start(Samples.session(Samples.tempDirectory()))
        await destination.setConnectedHandler { connects.withLock { $0 += 1 } }

        var match = WatchlistMatchData()
        match.entryUuid = "0f6b7c2e-0000-4000-8000-000000000001"
        match.label = "Lobby AP"
        match.matchType = .exact
        match.matchedField = .bssid
        match.bssid = "02:00:5e:00:53:01"
        await destination.acceptWatchlist(.match(WatchlistMatch(data: match)))
        var update = WatchlistEntryUpdateData()
        update.messageSequence = 42
        update.changeType = .snapshot
        await destination.acceptWatchlist(.entries(WatchlistEntryUpdate(data: update)))

        let received = try await subscriber.waitFor(count: 2)
        let deadline = ContinuousClock.now + .seconds(5)
        while connects.withLock({ $0 }) == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        await destination.stop()
        await subscriber.close()

        #expect(received.map(\.topic).sorted() == ["site-a/watchlist_entry_message", "site-a/watchlist_match_message"])
        let matchPayload = try #require(received.first { $0.topic.hasSuffix("watchlist_match_message") }?.payload)
        #expect(matchPayload.contains(#""messageType":"WatchlistMatch""#))
        #expect(matchPayload.contains(#""deviceName":"Field kit 2""#))
        #expect(matchPayload.contains(#""matchedField":"BSSID""#))
        let entryPayload = try #require(received.first { $0.topic.hasSuffix("watchlist_entry_message") }?.payload)
        #expect(entryPayload.contains(#""messageSequence":"42","changeType":"SNAPSHOT""#))
        #expect(connects.withLock { $0 } >= 1)
        // Watchlist messages are not survey records.
        #expect(await destination.snapshot().recordsAccepted == 0)
    }
}
#endif
