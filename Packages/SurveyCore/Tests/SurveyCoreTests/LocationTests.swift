import BoardKit
import BoardProtocol
import Foundation
import Testing
@testable import SurveyCore

@Suite("Location source policy and time")
struct LocationTests {
    let now = Fixtures.base

    func board(age: TimeInterval = 1, accuracy: Double = 4) -> LocationSample {
        LocationSample(latitude: 1, longitude: 2, horizontalAccuracy: accuracy, timestamp: now - age, source: .boardGPS)
    }

    func phone(age: TimeInterval = 1, accuracy: Double = 5) -> LocationSample {
        Fixtures.phoneFix(accuracy: accuracy, time: now - age)
    }

    @Test("Phone is the default when fresh and accurate")
    func phoneDefault() {
        let policy = LocationSourcePolicy()
        #expect(policy.preference == .phone)
        #expect(policy.choose(phone: phone(), board: board(), at: now)?.source == .phone)
    }

    @Test("Falls back to the board when the phone fix is missing, stale or poor")
    func fallback() {
        let policy = LocationSourcePolicy()
        #expect(policy.choose(phone: nil, board: board(), at: now)?.source == .boardGPS)
        #expect(policy.choose(phone: phone(age: 30), board: board(), at: now)?.source == .boardGPS)
        #expect(policy.choose(phone: phone(accuracy: 120), board: board(), at: now)?.source == .boardGPS)
        // A poor phone fix still beats nothing.
        #expect(policy.choose(phone: phone(accuracy: 120), board: nil, at: now)?.source == .phone)
        #expect(policy.choose(phone: phone(age: 30), board: board(age: 30), at: now) == nil)
    }

    @Test("Prefer board setting")
    func preferBoard() {
        let policy = LocationSourcePolicy(preference: .board)
        #expect(policy.choose(phone: phone(), board: board(), at: now)?.source == .boardGPS)
        #expect(policy.choose(phone: phone(), board: board(age: 60), at: now)?.source == .phone)
        let settings = SettingsStore.inMemory()
        #expect(settings[Settings.locationSource] == .phone)
        settings[Settings.locationSource] = .board
        #expect(settings[Settings.locationSource] == .board)
    }

    @Test("History finds the nearest fix, including late arrivals")
    func history() {
        var history = LocationHistory(capacity: 5)
        for second in [0, 1, 2, 4, 3] {
            history.append(Fixtures.phoneFix(latitude: Double(second), time: now + TimeInterval(second)))
        }
        #expect(history.samples.map(\.latitude) == [0, 1, 2, 3, 4])
        #expect(history.nearest(to: now + 2.4)?.latitude == 2)
        #expect(history.nearest(to: now + 2.6)?.latitude == 3)
        #expect(history.nearest(to: now - 10)?.latitude == 0)
        history.append(Fixtures.phoneFix(latitude: 5, time: now + 5))
        #expect(history.samples.count == 5)
        #expect(history.latest?.latitude == 5)
    }

    @Test("Board time to wall time")
    func boardClock() {
        var clock = BoardClock()
        let id = BoardID(UUID())
        let received = now + 5
        // Synced boards report epoch milliseconds.
        #expect(clock.wallTime(boardTimeMs: Fixtures.ms(now), synced: true, board: id, receivedAt: received) == now)
        // Before SetTime: uptime, mapped through the status offset.
        #expect(clock.wallTime(boardTimeMs: 10_000, synced: false, board: id, receivedAt: received) == received)
        var status = NSBBoardStatus()
        status.boardTimeMs = 20_000
        status.timeSynced = false
        clock.noteStatus(status, from: id, receivedAt: received)
        #expect(clock.wallTime(boardTimeMs: 18_000, synced: false, board: id, receivedAt: received) == received - 2)
        // A synced time far from the receive time is not trusted.
        #expect(clock.wallTime(boardTimeMs: 1_000, synced: true, board: id, receivedAt: received) == received)
    }

    @Test("Board GPS fixes become samples; invalid fixes are dropped")
    func gpsFix() throws {
        guard case .gps(var fix) = Fixtures.gps(latitude: 38.9, longitude: -77.0, hdop: 1.2) else { return }
        let sample = try #require(LocationSample(fix, wallTime: now))
        #expect(sample.source == .boardGPS)
        #expect(abs((sample.horizontalAccuracy ?? 0) - 6) < 0.01)
        #expect(sample.timestamp == now)
        fix.fixQuality = 0
        #expect(LocationSample(fix, wallTime: now) == nil)
    }

    @Test("Simulated walk moves at walking speed and loops")
    func simulatedWalk() async {
        let provider = SimulatedLocationProvider(startDate: now, timeSource: .manual)
        let first = provider.sample(atSeconds: 0), later = provider.sample(atSeconds: 60)
        let distance = first.point.distance(to: later.point)
        #expect(distance > 30 && distance < 150)
        #expect(provider.sample(atSeconds: 360).point.distance(to: first.point) < 1)
        #expect((first.speed ?? 0) > 0.5 && (first.speed ?? 0) < 3)

        let updates = provider.updates()
        provider.advance(bySeconds: 2)  // not running: nothing
        await provider.start(background: true)
        provider.advance(bySeconds: 2)
        await provider.stop()
        var received: [LocationSample] = []
        for await sample in updates {
            received.append(sample)
            if received.count == 2 { break }
        }
        #expect(received.map(\.timestamp) == [now + 3, now + 4])
    }

    @Test("A realtime walk started long after it was created stamps fixes with the current time")
    func simulatedWalkStartsLate() async {
        let provider = SimulatedLocationProvider(startDate: Date().addingTimeInterval(-60))
        let updates = provider.updates()
        await provider.start(background: true)
        var first: LocationSample?
        for await sample in updates {
            first = sample
            break
        }
        await provider.stop()
        let age = Date().timeIntervalSince(first?.timestamp ?? .distantPast)
        #expect(abs(age) < 2)
    }
}
