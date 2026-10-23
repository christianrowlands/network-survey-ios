import BoardProtocol
import Foundation
import Testing
@testable import BoardKit

@Suite("Simulated board roles")
struct SimulatedRoleTests {
    private func survey(role: NSBRole, channels: [UInt32] = [], ble: Bool = true, boardIndex: Int = 0, ms: UInt64 = 30_000)
        async throws -> (response: NSBControlResponse, events: [BoardEvent])
    {
        var harness = SimHarness(boards: 3, seed: 21)
        let id = harness.boardIDs[boardIndex]
        let response = try await harness.startSurvey(id, role: role, channels: channels, ble: ble)
        await harness.transport.advance(byMs: ms)
        return (response, await harness.finish())
    }

    @Test("BAND_24 hops only 2.4 GHz")
    func band24() async throws {
        let (response, events) = try await survey(role: .band24)
        guard case .configure(let result)? = response.payload else { Issue.record("no ConfigureResult"); return }
        #expect(result.channels == WifiChannels.band24)
        let wifi = events.records.filter { !$0.isBLE }
        #expect(!wifi.isEmpty)
        #expect(wifi.allSatisfy { $0.band == .ghz24 })
        #expect(events.statuses.allSatisfy { $0.role == .band24 && WifiChannels.band(of: $0.currentChannel) == .ghz24 })
    }

    @Test("BAND_5 hops only 5 GHz")
    func band5() async throws {
        let (_, events) = try await survey(role: .band5)
        let wifi = events.records.filter { !$0.isBLE }
        #expect(!wifi.isEmpty)
        #expect(wifi.allSatisfy { $0.band == .ghz5 })
    }

    @Test("BAND_5 is refused by a 2.4 GHz-only board")
    func band5OnSingleBandBoard() async throws {
        let (response, events) = try await survey(role: .band5, boardIndex: 2, ms: 2_000)
        #expect(response.result == .invalidArgument)
        // The refused Configure leaves the default AUTO plan in place, which on this board is 2.4 GHz.
        #expect(events.records.filter { !$0.isBLE }.allSatisfy { $0.band == .ghz24 })
        #expect(events.statuses.allSatisfy { $0.role == .auto })
    }

    @Test("FIXED_CHANNEL stays on its channel")
    func fixedChannel() async throws {
        let (_, events) = try await survey(role: .fixedChannel, channels: [36, 40], ble: false)
        let records = events.records
        #expect(!records.isEmpty)
        #expect(records.allSatisfy { $0.wifiChannel == 36 })
        #expect(events.statuses.allSatisfy { $0.currentChannel == 36 })
    }

    @Test("AUTO with a channel list only receives on those channels")
    func autoChannelList() async throws {
        let (response, events) = try await survey(role: .auto, channels: [1, 6, 11, 200], ble: false)
        guard case .configure(let result)? = response.payload else { Issue.record("no ConfigureResult"); return }
        #expect(result.channels == [1, 6, 11])
        let receive = events.records.compactMap { record -> UInt32? in
            switch record.kind {
            case .client(let client): client.channel
            case .probe(let probe): probe.channel
            default: nil
            }
        }
        #expect(!receive.isEmpty)
        #expect(Set(receive).isSubset(of: [1, 6, 11]))
        // AP records carry the AP's own channel; overlapping 2.4 GHz channels are heard up to two away.
        let apChannels = events.records.compactMap { if case .ap(let ap) = $0.kind { ap.channel } else { nil } }
        #expect(apChannels.allSatisfy { channel in [1, 6, 11].contains { abs(Int($0) - Int(channel)) <= 2 } })
        #expect(!events.records.contains { $0.isBLE })
    }

    @Test("BLE_SNIFFER sends only BLE")
    func bleSniffer() async throws {
        let (response, events) = try await survey(role: .bleSniffer)
        guard case .configure(let result)? = response.payload else { Issue.record("no ConfigureResult"); return }
        #expect(result.channels.isEmpty)
        #expect(!events.records.isEmpty)
        #expect(events.records.allSatisfy { $0.isBLE })
        #expect(events.statuses.allSatisfy { $0.currentChannel == 0 })
    }

    @Test("Configure flags turn record types off")
    func flags() async throws {
        var harness = SimHarness(seed: 4)
        let id = harness.boardIDs[0]
        try await harness.transport.connect(id)
        try await harness.hello(id)
        var config = NSBConfigure.make(role: .auto, ble: false)
        config.wifiClient = false
        config.wifiProbes = false
        try await harness.send(.configure(config), to: id)
        try await harness.send(.start(NSBStart()), to: id)
        await harness.transport.advance(byMs: 20_000)
        let records = await harness.finish().records
        #expect(!records.isEmpty)
        #expect(records.allSatisfy { if case .ap = $0.kind { true } else { false } })
    }
}

@Suite("Simulated link faults and multiple boards")
struct SimulatedLinkTests {
    @Test("Lost notifications show up as a sequence gap")
    func gapInjection() async throws {
        var harness = SimHarness(seed: 6)
        let id = harness.boardIDs[0]
        try await harness.startSurvey(id)
        await harness.transport.advance(byMs: 3_000)
        await harness.transport.injectLostNotifications(3, on: id)
        await harness.transport.advance(byMs: 3_000)
        let batches = await harness.finish().batches
        let gaps = batches.filter { $0.missedNotifications > 0 }
        #expect(gaps.count == 1)
        #expect(gaps.first?.missedNotifications == 3)
        // Sequence numbers are consecutive apart from the gap.
        let sequences = batches.map(\.sequence)
        #expect(sequences.first == 0)
        #expect(Int(sequences.last!) == batches.count - 1 + 3)
    }

    @Test("A dropped link buffers records and delivers them after reconnect")
    func disconnectAndReconnect() async throws {
        var harness = SimHarness(seed: 8)
        let id = harness.boardIDs[0]
        try await harness.startSurvey(id)
        await harness.transport.advance(byMs: 2_000)
        await harness.transport.injectDisconnect(id)
        let afterDrop = try? await harness.send(.ping(NSBPing()), to: id)
        #expect(afterDrop == nil)
        await harness.transport.advance(byMs: 5_000)
        try await harness.transport.connect(id)
        // A new connection needs Hello again.
        let refused = try await harness.send(.start(NSBStart()), to: id)
        #expect(refused.result == .invalidState)
        try await harness.hello(id)
        await harness.transport.advance(byMs: 2_000)
        let events = await harness.finish()

        #expect(events.states.contains(.disconnected(.linkLost)))
        // Buffered records arrive right after the reconnect, starting at sequence 0 with no gap.
        guard let reconnect = events.lastIndex(where: { if case .connectionState(_, .connected) = $0 { true } else { false } })
        else { Issue.record("no reconnect"); return }
        let after = Array(events[(reconnect + 1)...]).batches
        #expect(after.first?.sequence == 0)
        #expect(after.allSatisfy { $0.missedNotifications == 0 })
        let bufferedTimes = after.flatMap(\.batch.records).compactMap { record -> UInt64? in
            if case .ap(let ap) = record.kind { ap.boardTimeMs } else { nil }
        }
        let dropTime: UInt64 = 1_800_000_000_000 + 2_000
        #expect(bufferedTimes.contains { $0 > dropTime && $0 < dropTime + 5_000 })
        #expect(events.statuses.allSatisfy { $0.state == .surveying })
    }

    @Test("Several boards are discovered and survey independently")
    func multipleBoards() async throws {
        var harness = SimHarness(boards: 3, seed: 12)
        let discoveries = harness.transport.discoveries()
        await harness.transport.startScanning()
        var iterator = discoveries.makeAsyncIterator()
        let seen = await iterator.next() ?? []
        #expect(seen.count == 3)
        #expect(Set(seen.map(\.id)).count == 3)
        #expect(seen.allSatisfy { $0.isSimulated && $0.name.hasPrefix("NS-") })

        let ids = harness.boardIDs
        try await harness.startSurvey(ids[0], role: .band24, ble: false)
        try await harness.startSurvey(ids[1], role: .band5, ble: false)
        try await harness.startSurvey(ids[2], role: .bleSniffer)
        await harness.transport.advance(byMs: 10_000)
        let events = await harness.finish()
        #expect(events.records(from: ids[0]).allSatisfy { $0.band == .ghz24 })
        #expect(events.records(from: ids[1]).allSatisfy { $0.band == .ghz5 })
        #expect(events.records(from: ids[2]).allSatisfy { $0.isBLE })
        #expect(ids.allSatisfy { !events.records(from: $0).isEmpty })
    }
}
