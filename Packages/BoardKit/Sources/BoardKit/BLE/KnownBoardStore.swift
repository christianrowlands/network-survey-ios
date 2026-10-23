import BoardProtocol
import Foundation
import Synchronization

/// A board this phone has paired with. Only known boards are reconnected
/// silently; an unknown board is never connected without a user action. A
/// removed board keeps its entry (and both halves of the bond) so it is
/// recognised and can be added back without pairing again, but it is not
/// reconnected.
public struct KnownBoard: Codable, Hashable, Sendable, Identifiable {
    /// The stable board ID (or a provisional one stored by an older version).
    public var id: BoardID
    /// This phone's CoreBluetooth identifier for the board: the connection key.
    public var peripheralID: UUID?
    public var shortID: String
    public var name: String
    /// `NSBBoardModel` raw value (kept raw so unknown future models survive).
    public var modelRawValue: Int
    public var modelName: String
    public var lastConnected: Date
    /// When the user removed the board in the app; nil while it is in use.
    public var removedAt: Date?

    public init(
        id: BoardID, shortID: String, name: String, modelRawValue: Int, modelName: String = "", lastConnected: Date,
        peripheralID: UUID? = nil
    ) {
        self.id = id
        self.peripheralID = peripheralID
        self.shortID = shortID
        self.name = name
        self.modelRawValue = modelRawValue
        self.modelName = modelName
        self.lastConnected = lastConnected
    }

    public init(id: BoardID, info: NSBBoardInfo, at date: Date, peripheralID: UUID? = nil) {
        self.init(
            id: id, shortID: info.shortID, name: "NS-\(info.shortID)", modelRawValue: info.boardModel.rawValue,
            modelName: info.modelName, lastConnected: date, peripheralID: peripheralID ?? id.peripheralUUID
        )
    }

    /// A board read over BLE: its stable ID when Info has an address.
    public init(info: NSBBoardInfo, peripheralID: UUID, at date: Date) {
        self.init(id: BoardID(info: info) ?? BoardID(peripheralID), info: info, at: date, peripheralID: peripheralID)
    }

    /// The CoreBluetooth identifier to connect with.
    var connectionKey: UUID? { peripheralID ?? id.peripheralUUID }

    public var model: NSBBoardModel { NSBBoardModel(rawValue: modelRawValue) ?? .unspecified }
    public var isRemoved: Bool { removedAt != nil }
}

/// Persistence for known boards. Small and synchronous; implementations must be
/// safe to call from any thread.
public protocol KnownBoardStore: Sendable {
    func load() -> [KnownBoard]
    func save(_ boards: [KnownBoard])
}

extension KnownBoardStore {
    func upsert(_ board: KnownBoard) {
        // Also replaces an older entry for the same peripheral (a provisional ID).
        var boards = load().filter { $0.id != board.id && ($0.connectionKey == nil || $0.connectionKey != board.connectionKey) }
        boards.append(board)
        save(boards)
    }

    func remove(_ id: BoardID) {
        save(load().filter { $0.id != id })
    }

    func markRemoved(_ id: BoardID, connectionKey: UUID?, at date: Date) {
        save(load().map { board in
            guard board.id == id || (connectionKey != nil && board.connectionKey == connectionKey) else { return board }
            var removed = board
            removed.removedAt = date
            return removed
        })
    }
}

/// Keeps known boards as JSON in `UserDefaults`.
public final class UserDefaultsKnownBoardStore: KnownBoardStore, @unchecked Sendable {
    public static let defaultKey = "BoardKit.knownBoards"

    // UserDefaults is thread safe; it is only missing the annotation on older SDKs.
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [KnownBoard] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([KnownBoard].self, from: data)) ?? []
    }

    public func save(_ boards: [KnownBoard]) {
        guard let data = try? JSONEncoder().encode(boards) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Known boards in memory, for tests and the simulator.
public final class InMemoryKnownBoardStore: KnownBoardStore {
    private let boards: Mutex<[KnownBoard]>

    public init(_ boards: [KnownBoard] = []) {
        self.boards = Mutex(boards)
    }

    public func load() -> [KnownBoard] { boards.withLock { $0 } }
    public func save(_ boards: [KnownBoard]) { self.boards.withLock { $0 = boards } }
}
