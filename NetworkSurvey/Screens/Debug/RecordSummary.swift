import BoardProtocol
import Foundation

/// One board record flattened for a list row.
nonisolated struct RecordSummary: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case ap = "AP"
        case client = "Client"
        case probe = "Probe"
        case ble = "BLE"
        case gps = "GPS"
    }

    let id: Int
    let kind: Kind
    let title: String
    let identifier: String
    let detail: String
    let rssi: Int32?
    let tags: [String]

    init?(record: NSBRecord, id: Int) {
        self.id = id
        switch record.kind {
        case .ap(let ap):
            kind = .ap
            title = ap.ssidHidden ? "Hidden network" : String(decoding: ap.ssid, as: UTF8.self)
            identifier = Self.mac(ap.bssid)
            detail = "Ch \(ap.channel) · \(Self.band(ap.band)) · \(ap.beaconCount) beacons"
            rssi = ap.rssiLast
            tags = [Self.security(ap.security)] + (ap.ssidHidden ? ["Hidden"] : [])
        case .client(let client):
            kind = .client
            title = client.associatedBssid.isEmpty ? "Not associated" : "On \(Self.mac(client.associatedBssid))"
            identifier = Self.mac(client.clientMac)
            detail = "Ch \(client.channel) · \(client.frameCount) frames"
            rssi = client.rssiLast
            tags = client.locallyAdministered ? ["Random MAC"] : []
        case .probe(let probe):
            kind = .probe
            title = probe.ssid.isEmpty ? "Wildcard probe" : String(decoding: probe.ssid, as: UTF8.self)
            identifier = Self.mac(probe.clientMac)
            detail = "Ch \(probe.channel) · \(probe.count)×"
            rssi = probe.rssiLast
            tags = probe.locallyAdministered ? ["Random MAC"] : []
        case .ble(let ble):
            kind = .ble
            title = ble.localName.isEmpty ? "Unnamed device" : ble.localNameText
            identifier = Self.mac(ble.address)
            detail = ble.hasCompanyID ? String(format: "Company 0x%04X · %d×", ble.companyID, ble.count) : "\(ble.count)×"
            rssi = ble.rssiLast
            tags = ble.addressType == .random ? ["Random"] : []
        case .gps(let gps):
            kind = .gps
            title = String(format: "%.5f, %.5f", gps.latitude, gps.longitude)
            identifier = "Scout GPS"
            detail = "\(gps.satellites) satellites"
            rssi = nil
            tags = []
        case nil:
            return nil
        }
    }

    static func mac(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    static func band(_ band: NSBBand) -> String {
        switch band {
        case .ghz24: "2.4 GHz"
        case .ghz5: "5 GHz"
        case .ghz6: "6 GHz"
        default: "?"
        }
    }

    static func security(_ security: NSBSecurityType) -> String {
        switch security {
        case .open: "Open"
        case .wep: "WEP"
        case .wpa: "WPA"
        case .wpaWpa2: "WPA/WPA2"
        case .wpa2: "WPA2"
        case .wpa3: "WPA3"
        case .wpa2Wpa3: "WPA2/WPA3"
        case .owe: "OWE"
        default: "Unknown"
        }
    }
}
