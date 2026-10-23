import Foundation

extension BoardManager {
    /// Hands a board to a firmware update, which then drives it directly over
    /// the transport (OtaBegin, chunks, OtaEnd, reconnect after the reboot).
    /// Until `endFirmwareUpdate` the manager does not reconnect, adopt or
    /// handshake the board, and `connect` throws `.busy`. Not allowed while a
    /// survey runs. The transport link is left as it is.
    public func beginFirmwareUpdate(_ id: BoardID) throws {
        guard capture == nil else { throw BoardManagerError.surveyRunning }
        guard !busy.contains(id) else { throw BoardManagerError.busy }
        stopWanting(id)
        updating.insert(id)
        boards[id, default: BoardState()].isReady = false
        boards[id]?.isUpdating = true
    }

    /// Gives the board back: the manager connects it if needed (pending connect)
    /// and runs Hello and SetTime, so `boards[id].hello` and `info` show the new
    /// firmware. Returns at once; watch `events()` for `.ready` or `.incompatible`.
    public func endFirmwareUpdate(_ id: BoardID) {
        guard updating.remove(id) != nil else { return }
        boards[id]?.isUpdating = false
        wanted.insert(id)
        startReconnect(id)
    }
}
