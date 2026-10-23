import BoardProtocol
import Foundation

/// What the user asked a board to do. `.auto` boards share the channels.
public enum BoardRolePreference: Hashable, Sendable, Codable {
    case auto
    case band24
    case band5
    case fixedChannel(UInt32)
    case bleSniffer
}

/// The plan for one board: the role and channels it gets in its Configure.
public struct BoardAssignment: Equatable, Sendable {
    public var role: NSBRole
    /// Channels to hop, ascending (empty for a BLE sniffer).
    public var channels: [UInt32]
    /// BLE capture: continuous for a BLE sniffer, interleaved for a Wi-Fi role.
    public var ble: Bool
    /// The planner chose BLE_SNIFFER for an AUTO board.
    public var automaticSniffer: Bool

    public init(role: NSBRole, channels: [UInt32], ble: Bool, automaticSniffer: Bool = false) {
        self.role = role
        self.channels = channels
        self.ble = ble
        self.automaticSniffer = automaticSniffer
    }

    /// Nothing to do: the board is left idle.
    public static let idle = BoardAssignment(role: .auto, channels: [], ble: false)
    public static let sniffer = BoardAssignment(role: .bleSniffer, channels: [], ble: true)

    public var isIdle: Bool { role != .bleSniffer && channels.isEmpty }
}

/// Splits the work of a survey across up to four boards. Pure and
/// deterministic: the same boards, in the same order, give the same plan.
///
/// 1. Manual roles (fixed channel, band, BLE sniffer) are assigned first. A
///    manual role the board cannot honour (a 5 GHz channel on a 2.4 GHz-only
///    board, or BLE_SNIFFER with BLE off) falls back to AUTO.
/// 2. The enabled set is 2.4 GHz plus every 5 GHz channel an AUTO board can
///    receive, limited to `Options.channels`, without the channels manual Wi-Fi
///    roles already cover (unless nothing would be left).
/// 3. With both 5 GHz-capable and 2.4 GHz-only AUTO boards, the 2.4-only boards
///    share 2.4 GHz and the others share 5 GHz; otherwise all AUTO boards share
///    the whole set.
/// 4. Within a group, channels are split into disjoint sets balanced by weight
///    (greedy, heaviest channel first, to the lightest board).
/// 5. With BLE on and no sniffer, two or more AUTO boards give up one board as
///    BLE sniffer (the least capable, so no band loses coverage); otherwise the
///    lightest Wi-Fi board interleaves BLE.
///
/// Edge cases: a board left without channels hops every enabled channel it
/// supports (overlap is kept per board). With no Wi-Fi capture every
/// non-manual board becomes a BLE sniffer, or idles when BLE is off too.
public enum ChannelPlanner {
    public struct Board: Sendable, Equatable {
        public var id: BoardID
        public var supportedChannels: [UInt32]
        public var role: BoardRolePreference

        public init(id: BoardID, supportedChannels: [UInt32], role: BoardRolePreference = .auto) {
            self.id = id
            self.supportedChannels = supportedChannels
            self.role = role
        }

        public init(id: BoardID, bands: [NSBBand], role: BoardRolePreference = .auto) {
            self.init(id: id, supportedChannels: WifiChannels.supported(bands: bands), role: role)
        }

        func supports(_ channel: UInt32) -> Bool { supportedChannels.contains(channel) }
        var supports5GHz: Bool { supportedChannels.contains { WifiChannels.band(of: $0) == .ghz5 } }
    }

    public struct Options: Sendable, Equatable {
        /// Any Wi-Fi capture (AP, client, probe or raw) is on.
        public var wifi: Bool
        public var ble: Bool
        /// Channels the survey may use; empty means every supported channel.
        public var channels: [UInt32]
        /// Relative cost per channel (observed AP activity). Missing means 1.
        public var weights: [UInt32: Double]
        /// Turn one of several AUTO boards into the BLE sniffer.
        public var autoBLESniffer: Bool

        public init(
            wifi: Bool = true, ble: Bool = true, channels: [UInt32] = [], weights: [UInt32: Double] = [:],
            autoBLESniffer: Bool = true
        ) {
            self.wifi = wifi
            self.ble = ble
            self.channels = channels
            self.weights = weights
            self.autoBLESniffer = autoBLESniffer
        }
    }

    public static func plan(_ boards: [Board], options: Options = Options()) -> [BoardID: BoardAssignment] {
        var result: [BoardID: BoardAssignment] = [:]
        let allowed = { (channel: UInt32) in options.channels.isEmpty || options.channels.contains(channel) }
        var autos: [Board] = []
        var covered = Set<UInt32>()

        // 1. Manual roles.
        for board in boards {
            switch board.role {
            case .auto:
                autos.append(board)
            case .bleSniffer:
                // With BLE off a sniffer would capture what the survey excludes.
                if options.ble { result[board.id] = .sniffer } else { autos.append(board) }
            case .fixedChannel(let channel):
                guard options.wifi, board.supports(channel) else {
                    autos.append(board)
                    continue
                }
                result[board.id] = BoardAssignment(role: .fixedChannel, channels: [channel], ble: false)
                covered.insert(channel)
            case .band24, .band5:
                let band: NSBBand = board.role == .band24 ? .ghz24 : .ghz5
                let channels = board.supportedChannels.filter { WifiChannels.band(of: $0) == band && allowed($0) }.sorted()
                guard options.wifi, !channels.isEmpty else {
                    autos.append(board)
                    continue
                }
                result[board.id] = BoardAssignment(role: band == .ghz24 ? .band24 : .band5, channels: channels, ble: false)
                covered.formUnion(channels)
            }
        }
        let hasSniffer = { result.values.contains { $0.role == .bleSniffer } }

        guard options.wifi else {
            for board in autos { result[board.id] = options.ble ? .sniffer : .idle }
            return result
        }

        // 5, first half: one of several AUTO boards becomes the BLE sniffer.
        if options.ble, options.autoBLESniffer, !hasSniffer(), autos.count >= 2 {
            let pick = autos.indices.min { lhs, rhs in
                (autos[lhs].supportedChannels.count, -lhs) < (autos[rhs].supportedChannels.count, -rhs)
            }!
            result[autos[pick].id] = BoardAssignment(role: .bleSniffer, channels: [], ble: true, automaticSniffer: true)
            autos.remove(at: pick)
        }

        // 2. Enabled channels.
        let receivable = Set(autos.flatMap(\.supportedChannels))
        let enabled = (WifiChannels.band24 + WifiChannels.band5).filter { allowed($0) && receivable.contains($0) }
        var pool = enabled.filter { !covered.contains($0) }
        if pool.isEmpty { pool = enabled }

        // 3. Groups by capability.
        let fiveCapable = autos.filter { board in pool.contains { WifiChannels.band(of: $0) == .ghz5 && board.supports($0) } }
        let twoOnly = autos.filter { board in !fiveCapable.contains { $0.id == board.id } }
        let groups: [(members: [Board], channels: [UInt32])] =
            if !fiveCapable.isEmpty, !twoOnly.isEmpty {
                [
                    (twoOnly, pool.filter { WifiChannels.band(of: $0) == .ghz24 }),
                    (fiveCapable, pool.filter { WifiChannels.band(of: $0) == .ghz5 }),
                ]
            } else {
                [(autos, pool)]
            }

        // 4. Weight-balanced disjoint sets.
        for group in groups {
            let parts = partition(group.channels, among: group.members, weights: options.weights)
            for (index, board) in group.members.enumerated() {
                let channels = parts[index].isEmpty ? enabled.filter(board.supports) : parts[index]
                result[board.id] = channels.isEmpty ? .idle : BoardAssignment(role: .auto, channels: channels, ble: false)
            }
        }

        // 5, second half: BLE interleave on the lightest Wi-Fi board.
        if options.ble, !hasSniffer() {
            let wifiBoards = boards.filter { result[$0.id].map { !$0.isIdle && $0.role != .bleSniffer } ?? false }
            let autoBoards = wifiBoards.filter { result[$0.id]?.role == .auto }
            let candidates = autoBoards.isEmpty ? wifiBoards : autoBoards
            let pick = candidates.enumerated().min { lhs, rhs in
                let left = result[lhs.element.id]!.channels, right = result[rhs.element.id]!.channels
                return (load(left, options.weights), left.count, lhs.offset) < (load(right, options.weights), right.count, rhs.offset)
            }
            if let pick { result[pick.element.id]?.ble = true }
        }
        return result
    }

    /// Greedy longest-processing-time split: heaviest channel first, each to the
    /// eligible board with the lowest load (then fewest channels, then order).
    static func partition(_ channels: [UInt32], among members: [Board], weights: [UInt32: Double]) -> [[UInt32]] {
        var parts = Array(repeating: [UInt32](), count: members.count)
        var loads = Array(repeating: 0.0, count: members.count)
        let ordered = channels.sorted { (weight($0, weights), $1) > (weight($1, weights), $0) }
        for channel in ordered {
            let eligible = members.indices.filter { members[$0].supports(channel) }
            guard let pick = eligible.min(by: { (loads[$0], parts[$0].count, $0) < (loads[$1], parts[$1].count, $1) }) else {
                continue
            }
            parts[pick].append(channel)
            loads[pick] += weight(channel, weights)
        }
        return parts.map { $0.sorted() }
    }

    static func weight(_ channel: UInt32, _ weights: [UInt32: Double]) -> Double {
        max(weights[channel] ?? 1, 0)
    }

    static func load(_ channels: [UInt32], _ weights: [UInt32: Double]) -> Double {
        channels.reduce(0) { $0 + weight($1, weights) }
    }
}
