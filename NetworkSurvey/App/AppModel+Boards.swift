import BoardKit
import BoardProtocol
import Foundation

extension AppModel {
    /// Boards the user is working with: connected, connecting, reconnecting or
    /// in the running survey. Sorted by short ID, demo boards last.
    var boardsInUse: [BoardID] {
        boardManager.boards
            .filter { $0.value.connection.isConnected || $0.value.reconnect != nil || $0.value.assignment != nil
                || $0.value.connection == .connecting }
            .map(\.key)
            .sorted { lhs, rhs in
                (isDemo(lhs) ? 1 : 0, shortID(lhs)) < (isDemo(rhs) ? 1 : 0, shortID(rhs))
            }
    }

    func shortID(_ board: BoardID) -> String {
        if let id = boardManager.boards[board]?.info?.shortID, !id.isEmpty { return id }
        if let id = boardManager.discovered.first(where: { $0.id == board })?.shortID { return id }
        return String(board.description.prefix(4))
    }

    func boardName(_ board: BoardID) -> String {
        BoardText.name(shortID: shortID(board))
    }

    func role(of board: BoardID) -> BoardRolePreference {
        boardManager.roles[board] ?? .auto
    }

    func setRole(_ role: BoardRolePreference, for board: BoardID) async {
        roleStore.save(role, for: board)
        await boardManager.setRole(role, for: board)
    }

    /// Connects (pairing on first use). Returns a message to show when it fails.
    func connect(_ board: BoardID) async -> String? {
        if !isDemo(board) { await setUpBluetooth() }
        do {
            try await boardManager.connect(board)
            return nil
        } catch {
            return Self.connectMessage(error, name: boardName(board))
        }
    }

    func disconnect(_ board: BoardID) async {
        await boardManager.disconnect(board)
    }

    /// Stops using the Scout, keeping the pairing on both sides so it can be
    /// added back without pairing. `wipeBonds` also has a connected Scout erase
    /// its pairings; returns whether it confirmed.
    @discardableResult
    func forget(_ board: BoardID, wipeBonds: Bool = false) async -> Bool {
        roleStore.save(nil, for: board)
        return await boardManager.forget(board, wipeBonds: wipeBonds)
    }

    static func connectMessage(_ error: any Error, name: String) -> String {
        switch error {
        case BoardManagerError.tooManyBoards: return "Four Scouts are connected, the most one iPhone can use. Disconnect one first."
        case BoardManagerError.busy: return "\(name) is already connecting."
        case BoardManagerError.incompatible(let reason): return reason
        case BoardManagerError.rejected(_, let message): return "\(name) refused the connection (\(message)). Unplug it for a moment to restart it, then try again."
        case let error as BoardTransportError:
            switch error {
            case .bondMissing: return BoardText.issueMessage(.bondMissing, name: name)
            case .pairingRejected: return BoardText.issueMessage(.pairingRejected, name: name)
            case .timeout: return "\(name) did not answer. Hold it next to your iPhone and try again."
            case .bluetoothUnavailable: return "Bluetooth is not available. Turn it on in Control Center and allow Network Survey to use it."
            case .cancelled: return "Connecting was cancelled."
            default: return "Could not connect to \(name). Hold it next to your iPhone and try again."
            }
        default:
            return "Could not connect to \(name). Hold it next to your iPhone and try again. (\(error.localizedDescription))"
        }
    }
}
