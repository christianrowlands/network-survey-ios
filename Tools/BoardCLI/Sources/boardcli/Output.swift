import BoardKit
import BoardProtocol
import Foundation

enum Explain {
    static func error(_ error: any Error) -> String {
        switch error {
        case BoardTransportError.bondMissing:
            "The board no longer has this Mac's pairing (CBError 14). Remove the board in System Settings > Bluetooth, then pair again."
        case BoardTransportError.pairingRejected:
            "Pairing did not complete. Accept the pairing prompt, or, if the board is paired with another device, hold BOOT for about 3 seconds to open its pairing window."
        case BoardTransportError.bluetoothUnavailable(let state) where state == "unauthorized":
            "Bluetooth permission is missing for this terminal app: System Settings > Privacy & Security > Bluetooth."
        case BoardTransportError.bluetoothUnavailable(let state):
            "Bluetooth is not available (\(state))."
        case BoardManagerError.incompatible(let reason):
            reason
        default:
            String(describing: error)
        }
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }

    static func flags(_ board: DiscoveredBoard) -> String {
        [
            board.pairingMode ? "P" : "-", board.hasBond ? "B" : "-", board.hasGPS ? "G" : "-",
            board.supports5GHz ? "5" : "-", board.isKnown ? "K" : "-",
        ].joined()
    }

    static func info(_ info: NSBBoardInfo, id: BoardID) -> String {
        """
        Board        NS-\(info.shortID)  \(id)
        Model        \(info.boardModel)\(info.modelName.isEmpty ? "" : " (\(info.modelName))")  chip \(info.chip)
        Firmware     \(info.firmwareVersion)
        Protocol     \(info.protocolMajor).\(info.protocolMinor)  (app \(NSBProtocolVersion.major.rawValue).\(NSBProtocolVersion.minor.rawValue))
        Bands        \(info.bands.map { $0 == .ghz5 ? "5 GHz" : $0 == .ghz24 ? "2.4 GHz" : "\($0)" }.joined(separator: ", "))
        GPS          \(info.gpsPresent ? "present" : "none")
        MTU wanted   \(info.preferredMtu)
        BT address   \(info.btAddress.map { String(format: "%02X", $0) }.joined(separator: ":"))
        """
    }

    static let streamHeader = pad("t", 5) + pad("board", 10) + pad("ap", 7) + pad("client", 7) + pad("probe", 7) + pad("ble", 7)
        + pad("gps", 5) + pad("rec/s", 7) + pad("gaps", 6) + pad("drops", 7) + "ch"

    static func streamLine(second: Int, name: String, counters: BoardCounters, perSecond: Int, status: NSBBoardStatus?) -> String {
        let kinds = counters.recordsByKind
        return pad("\(second)", 5) + pad(name, 10) + pad("\(kinds[.ap, default: 0])", 7) + pad("\(kinds[.client, default: 0])", 7)
            + pad("\(kinds[.probe, default: 0])", 7) + pad("\(kinds[.ble, default: 0])", 7) + pad("\(kinds[.gps, default: 0])", 5)
            + pad("\(perSecond)", 7) + pad("\(counters.missedNotifications)", 6) + pad("\(counters.droppedRecords)", 7)
            + "\(status?.currentChannel ?? 0)"
    }

    static func summary(name: String, counters: BoardCounters, elapsed: Duration) -> String {
        let secs = max(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18, 0.001)
        let kinds = BoardRecordKind.allCases.map { "\($0.rawValue) \(counters.recordsByKind[$0, default: 0])" }.joined(separator: ", ")
        return "\(name): \(counters.records) records (\(kinds)), \(String(format: "%.1f", Double(counters.records) / secs)) records/s, "
            + "\(counters.batches) batches, gaps \(counters.missedNotifications) notifications, board drops \(counters.droppedRecords) records"
            + " / \(counters.droppedRxFrames) rx frames, link gaps \(counters.linkGaps)"
    }

    static func seconds(_ duration: Duration) -> String {
        String(format: "%.1f s", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }
}

enum RecordLine {
    static func describe(_ record: NSBRecord) -> String {
        switch record.kind {
        case .ap(let ap):
            "ap     \(mac(ap.bssid))  ch \(ap.channel)  \(ap.rssiLast) dBm  \(ap.ssidHidden ? "<hidden>" : String(decoding: ap.ssid, as: UTF8.self))"
        case .client(let client):
            "client \(mac(client.clientMac))  ch \(client.channel)  \(client.rssiLast) dBm  bssid \(client.associatedBssid.isEmpty ? "-" : mac(client.associatedBssid))"
        case .probe(let probe):
            "probe  \(mac(probe.clientMac))  ch \(probe.channel)  \(probe.rssiLast) dBm  \(probe.ssid.isEmpty ? "<wildcard>" : String(decoding: probe.ssid, as: UTF8.self))"
        case .ble(let ble):
            "ble    \(mac(ble.address))  \(ble.rssiLast) dBm  \(ble.localNameText)"
        case .gps(let gps):
            "gps    \(gps.latitude), \(gps.longitude)"
        case nil:
            "unknown record"
        }
    }

    static func mac(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
