import BoardProtocol
import Foundation
import Testing
@testable import BoardKit

@Suite("Channel planner")
struct ChannelPlannerTests {
    static let dual: [NSBBand] = [.ghz24, .ghz5]
    static let only24: [NSBBand] = [.ghz24]
    static let all = WifiChannels.band24 + WifiChannels.band5

    static func id(_ n: UInt8) -> BoardID {
        BoardID(UUID(uuid: (n, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, n)))
    }

    static func board(_ n: UInt8, _ bands: [NSBBand], _ role: BoardRolePreference = .auto) -> ChannelPlanner.Board {
        ChannelPlanner.Board(id: id(n), bands: bands, role: role)
    }

    /// Every AUTO board's channels are disjoint from the others in its group and
    /// supported by the board.
    static func checkSupported(_ boards: [ChannelPlanner.Board], _ plan: [BoardID: BoardAssignment]) {
        for board in boards {
            guard let assignment = plan[board.id] else {
                Issue.record("no assignment for \(board.id)")
                continue
            }
            #expect(assignment.channels.allSatisfy(board.supportedChannels.contains))
            #expect(assignment.channels == assignment.channels.sorted())
        }
    }

    static func autoChannels(_ plan: [BoardID: BoardAssignment]) -> [[UInt32]] {
        plan.values.filter { $0.role == .auto }.map(\.channels)
    }

    @Test("One dual-band board hops everything and interleaves BLE")
    func singleDualBand() {
        let plan = ChannelPlanner.plan([Self.board(1, Self.dual)])
        #expect(plan[Self.id(1)] == BoardAssignment(role: .auto, channels: Self.all, ble: true))
    }

    @Test("One 2.4 GHz-only board hops 1 to 13")
    func single24() {
        let plan = ChannelPlanner.plan([Self.board(1, Self.only24)])
        #expect(plan[Self.id(1)]?.channels == WifiChannels.band24)
        #expect(plan[Self.id(1)]?.ble == true)
    }

    @Test("Two dual-band boards without BLE split the full set evenly")
    func twoDualNoBLE() {
        let boards = [Self.board(1, Self.dual), Self.board(2, Self.dual)]
        let plan = ChannelPlanner.plan(boards, options: .init(ble: false))
        let sets = Self.autoChannels(plan)
        #expect(sets.count == 2)
        #expect(Set(sets[0]).isDisjoint(with: sets[1]))
        #expect(Set(sets.flatMap { $0 }) == Set(Self.all))
        #expect(abs(sets[0].count - sets[1].count) <= 1)
        #expect(plan.values.allSatisfy { !$0.ble })
        Self.checkSupported(boards, plan)
    }

    @Test("Two dual-band boards with BLE: one becomes the sniffer, the other hops everything")
    func twoDualWithBLE() {
        let plan = ChannelPlanner.plan([Self.board(1, Self.dual), Self.board(2, Self.dual)])
        #expect(plan[Self.id(2)] == BoardAssignment(role: .bleSniffer, channels: [], ble: true, automaticSniffer: true))
        #expect(plan[Self.id(1)] == BoardAssignment(role: .auto, channels: Self.all, ble: false))
    }

    @Test("Automatic sniffer can be turned off: the lighter board interleaves")
    func noAutoSniffer() {
        let boards = [Self.board(1, Self.dual), Self.board(2, Self.only24)]
        let plan = ChannelPlanner.plan(boards, options: .init(autoBLESniffer: false))
        #expect(!plan.values.contains { $0.role == .bleSniffer })
        // Mixed capabilities: the 2.4-only board gets 2.4 GHz (13), the dual board 5 GHz (25).
        #expect(plan[Self.id(2)]?.channels == WifiChannels.band24)
        #expect(plan[Self.id(1)]?.channels == WifiChannels.band5)
        #expect(plan[Self.id(2)]?.ble == true)
        #expect(plan[Self.id(1)]?.ble == false)
    }

    @Test("Mixed 2.4-only and 5 GHz boards without BLE: bands go to the matching boards")
    func mixedNoBLE() {
        let boards = [Self.board(1, Self.dual), Self.board(2, Self.only24), Self.board(3, Self.dual)]
        let plan = ChannelPlanner.plan(boards, options: .init(ble: false))
        #expect(plan[Self.id(2)]?.channels == WifiChannels.band24)
        let five = [plan[Self.id(1)]!.channels, plan[Self.id(3)]!.channels]
        #expect(five.allSatisfy { $0.allSatisfy { WifiChannels.band(of: $0) == .ghz5 } })
        #expect(Set(five[0]).isDisjoint(with: five[1]))
        #expect(Set(five.flatMap { $0 }) == Set(WifiChannels.band5))
        Self.checkSupported(boards, plan)
    }

    @Test("Mixed boards with BLE: the 2.4-only board becomes the sniffer so 5 GHz keeps coverage")
    func mixedWithBLE() {
        let plan = ChannelPlanner.plan([Self.board(1, Self.dual), Self.board(2, Self.only24)])
        #expect(plan[Self.id(2)]?.role == .bleSniffer)
        #expect(plan[Self.id(2)]?.automaticSniffer == true)
        #expect(plan[Self.id(1)]?.channels == Self.all)
    }

    @Test("Four boards (two dual, two 2.4-only) with BLE")
    func fourBoards() {
        let boards = [Self.board(1, Self.dual), Self.board(2, Self.only24), Self.board(3, Self.dual), Self.board(4, Self.only24)]
        let plan = ChannelPlanner.plan(boards)
        // The last least-capable board sniffs, the other 2.4-only board takes 2.4 GHz.
        #expect(plan[Self.id(4)]?.role == .bleSniffer)
        #expect(plan[Self.id(2)]?.channels == WifiChannels.band24)
        let five = [plan[Self.id(1)]!.channels, plan[Self.id(3)]!.channels]
        #expect(Set(five.flatMap { $0 }) == Set(WifiChannels.band5))
        #expect(five[0].count + five[1].count == WifiChannels.band5.count)
        #expect(plan.values.filter(\.ble).count == 1)
        Self.checkSupported(boards, plan)
    }

    @Test("Fixed channel is assigned first and removed from the AUTO set")
    func fixedFirst() {
        let boards = [Self.board(1, Self.dual, .fixedChannel(6)), Self.board(2, Self.dual)]
        let plan = ChannelPlanner.plan(boards)
        #expect(plan[Self.id(1)] == BoardAssignment(role: .fixedChannel, channels: [6], ble: false))
        #expect(plan[Self.id(2)]?.channels == Self.all.filter { $0 != 6 })
        // Only one AUTO board, so no automatic sniffer: it interleaves BLE.
        #expect(plan[Self.id(2)]?.ble == true)
    }

    @Test("A fixed channel the board cannot receive falls back to AUTO")
    func fixedUnsupported() {
        let plan = ChannelPlanner.plan([Self.board(1, Self.only24, .fixedChannel(36))], options: .init(ble: false))
        #expect(plan[Self.id(1)] == BoardAssignment(role: .auto, channels: WifiChannels.band24, ble: false))
    }

    @Test("A manual BLE sniffer stops automatic sniffers and interleave")
    func manualSniffer() {
        let boards = [Self.board(1, Self.dual), Self.board(2, Self.dual), Self.board(3, Self.only24, .bleSniffer)]
        let plan = ChannelPlanner.plan(boards)
        #expect(plan[Self.id(3)] == .sniffer)
        #expect(plan.values.filter { $0.role == .bleSniffer }.count == 1)
        #expect(plan[Self.id(1)]?.ble == false && plan[Self.id(2)]?.ble == false)
        #expect(Set(Self.autoChannels(plan).flatMap { $0 }) == Set(Self.all))
    }

    @Test("A BAND_24 board covers 2.4 GHz and leaves 5 GHz to AUTO boards")
    func bandRole() {
        let plan = ChannelPlanner.plan([Self.board(1, Self.dual, .band24), Self.board(2, Self.dual)], options: .init(ble: false))
        #expect(plan[Self.id(1)] == BoardAssignment(role: .band24, channels: WifiChannels.band24, ble: false))
        #expect(plan[Self.id(2)]?.channels == WifiChannels.band5)
    }

    @Test("BAND_5 on a 2.4-only board falls back to AUTO")
    func band5OnC6() {
        let plan = ChannelPlanner.plan([Self.board(1, Self.only24, .band5)], options: .init(ble: false))
        #expect(plan[Self.id(1)]?.role == .auto)
        #expect(plan[Self.id(1)]?.channels == WifiChannels.band24)
    }

    @Test("Busy channels are spread across boards and loads balance")
    func weights() {
        let boards = [Self.board(1, Self.only24), Self.board(2, Self.only24), Self.board(3, Self.only24)]
        let weights: [UInt32: Double] = [1: 20, 6: 20, 11: 20]
        let plan = ChannelPlanner.plan(boards, options: .init(ble: false, weights: weights))
        let sets = boards.map { plan[$0.id]!.channels }
        for busy: UInt32 in [1, 6, 11] {
            #expect(sets.filter { $0.contains(busy) }.count == 1)
        }
        #expect(sets.allSatisfy { set in [1, 6, 11].filter(set.contains).count == 1 })
        let loads = sets.map { ChannelPlanner.load($0, weights) }
        #expect(loads.max()! - loads.min()! <= 1)
    }

    @Test("BLE interleave goes to the lightest board by weight")
    func interleaveLightest() {
        let boards = [Self.board(1, Self.only24), Self.board(2, Self.only24)]
        let weights: [UInt32: Double] = [1: 30]
        let plan = ChannelPlanner.plan(boards, options: .init(weights: weights, autoBLESniffer: false))
        let heavy = boards.first { plan[$0.id]!.channels.contains(1) }!
        let light = boards.first { $0.id != heavy.id }!
        #expect(plan[light.id]?.ble == true)
        #expect(plan[heavy.id]?.ble == false)
    }

    @Test("A channel restriction is respected")
    func restriction() {
        let boards = [Self.board(1, Self.dual), Self.board(2, Self.dual)]
        let plan = ChannelPlanner.plan(boards, options: .init(ble: false, channels: [1, 6, 11, 36, 149]))
        #expect(Set(Self.autoChannels(plan).flatMap { $0 }) == [1, 6, 11, 36, 149])
    }

    @Test("More boards than channels: leftover boards hop what they can")
    func moreBoardsThanChannels() {
        let boards = [Self.board(1, Self.only24), Self.board(2, Self.only24), Self.board(3, Self.only24)]
        let plan = ChannelPlanner.plan(boards, options: .init(ble: false, channels: [1, 6]))
        #expect(boards.allSatisfy { !(plan[$0.id]?.channels.isEmpty ?? true) })
        #expect(Set(boards.flatMap { plan[$0.id]!.channels }) == [1, 6])
    }

    @Test("No Wi-Fi capture: AUTO boards sniff BLE, or idle when BLE is off too")
    func noWifi() {
        let boards = [Self.board(1, Self.dual), Self.board(2, Self.only24)]
        #expect(ChannelPlanner.plan(boards, options: .init(wifi: false)).values.allSatisfy { $0 == .sniffer })
        #expect(ChannelPlanner.plan(boards, options: .init(wifi: false, ble: false)).values.allSatisfy { $0.isIdle })
    }

    @Test("Deterministic: same input, same plan")
    func deterministic() {
        let boards = [Self.board(1, Self.dual), Self.board(2, Self.dual), Self.board(3, Self.dual)]
        let options = ChannelPlanner.Options(weights: [36: 4, 6: 3, 149: 2])
        #expect(ChannelPlanner.plan(boards, options: options) == ChannelPlanner.plan(boards, options: options))
    }

    @Test("Any mix of 1 to 4 boards: full coverage, disjoint AUTO sets per band, at most one BLE duty", arguments: 0..<200)
    func randomized(seed: Int) {
        var rng = SeededGenerator(seed: UInt64(seed + 1))
        let count = Int.random(in: 1...4, using: &rng)
        let ble = Bool.random(using: &rng)
        let boards = (0..<count).map { index in
            Self.board(UInt8(index + 1), Bool.random(using: &rng) ? Self.dual : Self.only24)
        }
        let plan = ChannelPlanner.plan(boards, options: .init(ble: ble))
        Self.checkSupported(boards, plan)
        let wifi = plan.values.filter { $0.role == .auto }
        let receivable = Set(boards.filter { plan[$0.id]?.role == .auto }.flatMap(\.supportedChannels))
        #expect(Set(wifi.flatMap(\.channels)) == receivable)
        #expect(wifi.map(\.channels.count).reduce(0, +) == receivable.count, "AUTO sets overlap")
        if ble {
            let sniffers = plan.values.filter { $0.role == .bleSniffer }.count
            let interleaved = plan.values.filter { $0.role != .bleSniffer && $0.ble }.count
            #expect(sniffers + interleaved == 1)
            #expect(sniffers == (count >= 2 ? 1 : 0))
        } else {
            #expect(plan.values.allSatisfy { !$0.ble })
        }
    }
}
