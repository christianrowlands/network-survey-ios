import BoardProtocol
import Foundation
import SurveyCore
import SwiftUI

/// Display text for the values the lists, details and map show.
enum DataFormat {
    /// Bands offered by the band filters: the ones a board can receive (no 6 GHz).
    static let filterBands: [NSBBand] = [.ghz24, .ghz5]

    static func band(_ raw: Int) -> String {
        switch NSBBand(rawValue: raw) {
        case .ghz24: "2.4 GHz"
        case .ghz5: "5 GHz"
        case .ghz6: "6 GHz"
        default: "Unknown band"
        }
    }

    static func bandColor(_ raw: Int) -> Color {
        switch NSBBand(rawValue: raw) {
        case .ghz5: Theme.Colors.band5
        case .ghz6: Theme.Colors.band6
        default: Theme.Colors.band24
        }
    }

    static func security(_ raw: Int) -> String {
        switch NSBSecurityType(rawValue: raw) {
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

    /// Open and WEP read as weak; everything else as protected.
    static func securityColor(_ raw: Int) -> Color {
        switch NSBSecurityType(rawValue: raw) {
        case .open, .wep: Theme.Colors.tagOpen
        default: Theme.Colors.tagSecurity
        }
    }

    static func channelWidth(_ raw: Int) -> String? {
        switch NSBChannelWidth(rawValue: raw) {
        case .mhz20: "20 MHz"
        case .mhz40: "40 MHz"
        case .mhz80: "80 MHz"
        case .mhz160: "160 MHz"
        case .mhz80P80: "80+80 MHz"
        case .mhz320: "320 MHz"
        default: nil
        }
    }

    /// Wi-Fi generations from the PHY capability bits, newest first.
    static func standards(phyFlags: Int) -> String? {
        var names: [String] = []
        if phyFlags & NSBPhyFlag.eht.rawValue != 0 { names.append("Wi-Fi 7") }
        if phyFlags & NSBPhyFlag.he.rawValue != 0 { names.append("Wi-Fi 6") }
        if phyFlags & NSBPhyFlag.vht.rawValue != 0 { names.append("Wi-Fi 5") }
        if phyFlags & NSBPhyFlag.ht.rawValue != 0 { names.append("Wi-Fi 4") }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    /// How a client was seen, from its `NSBClientSource` bits.
    static func clientSources(_ flags: Int) -> String? {
        let names: [(NSBClientSource, String)] = [
            (.data, "Data"), (.nullData, "Null data"), (.probeReq, "Probe request"), (.assocReq, "Association"),
            (.reassocReq, "Reassociation"), (.auth, "Authentication"), (.action, "Action"),
        ]
        let seen = names.filter { flags & $0.0.rawValue != 0 }.map(\.1)
        return seen.isEmpty ? nil : seen.joined(separator: ", ")
    }

    static func bleAddressType(_ raw: Int) -> String {
        switch NSBBleAddressType(rawValue: raw) {
        case .public: "Public"
        case .random: "Random"
        case .anonymous: "Anonymous"
        default: "Unknown"
        }
    }

    static func bleAdvType(_ raw: Int) -> String {
        switch NSBBleAdvType(rawValue: raw) {
        case .advInd: "Connectable"
        case .advDirectInd: "Directed"
        case .advScanInd: "Scannable"
        case .advNonconnInd: "Non-connectable"
        case .extended: "Extended"
        default: "Unknown"
        }
    }

    /// AKM suite names from the stored comma-separated selectors
    /// ((OUI << 8) | type), for example "PSK, SAE".
    static func akmSuites(_ csv: String) -> String {
        suites(csv, names: [
            1: "802.1X", 2: "PSK", 3: "FT-802.1X", 4: "FT-PSK", 5: "802.1X-SHA256", 6: "PSK-SHA256", 8: "SAE",
            9: "FT-SAE", 11: "802.1X-Suite-B", 12: "802.1X-Suite-B-192", 13: "FT-802.1X-SHA384", 18: "OWE",
            24: "SAE-EXT-KEY", 25: "FT-SAE-EXT-KEY",
        ])
    }

    /// Cipher suite names, for example "CCMP-128".
    static func cipherSuites(_ csv: String) -> String {
        suites(csv, names: [
            1: "WEP-40", 2: "TKIP", 4: "CCMP-128", 5: "WEP-104", 6: "BIP-CMAC-128", 8: "GCMP-128", 9: "GCMP-256",
            10: "CCMP-256", 11: "BIP-GMAC-128", 12: "BIP-GMAC-256", 13: "BIP-CMAC-256",
        ])
    }

    /// Selectors under the IEEE OUI 00-0F-AC (and WPA's 00-50-F2) get names;
    /// others show as "OUI:type", for example "00-50-F2:2".
    private static func suites(_ csv: String, names: [Int: String]) -> String {
        csv.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.map { selector in
            let oui = selector >> 8, type = selector & 0xFF
            if oui == 0x000FAC || oui == 0x0050F2, let name = names[type] { return name }
            let ouiText = String(format: "%02X-%02X-%02X", (oui >> 16) & 0xFF, (oui >> 8) & 0xFF, oui & 0xFF)
            return "\(ouiText):\(type)"
        }
        .joined(separator: ", ")
    }

    /// A BLE random address is private (resolvable or non-resolvable) unless
    /// its two top bits are 11, which marks a static random address.
    static func isPrivateBLEAddress(_ address: String, addressType: Int) -> Bool {
        guard NSBBleAddressType(rawValue: addressType) == .random,
              let first = UInt8(address.prefix(2), radix: 16) else { return false }
        return first & 0xC0 != 0xC0
    }

    static func dBm(_ value: Int) -> String {
        "\(value) dBm"
    }

    static func ssid(_ ssid: String?, hidden: Bool) -> String {
        if let ssid, !ssid.isEmpty { return ssid }
        return hidden ? "Hidden network" : "No name"
    }

    /// A network name from probe requests; empty for a wildcard probe.
    static func probedNetwork(_ ssid: String) -> String {
        ssid.isEmpty ? "Any network (wildcard)" : ssid
    }

    /// "12 s ago", "4 min ago", relative to `now`.
    static func ago(_ date: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<5: return "now"
        case ..<60: return "\(seconds) s ago"
        case ..<3600: return "\(seconds / 60) min ago"
        case ..<86_400: return "\(seconds / 3600) h ago"
        default: return date.formatted(date: .abbreviated, time: .omitted)
        }
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number)
    }

    /// "1 client", "1,204 clients".
    static func count(_ value: Int, _ noun: String) -> String {
        "\(count(value)) \(value == 1 ? noun : noun + "s")"
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// A distance in the chosen units: meters or feet, kilometers or miles.
    static func distance(_ meters: Double, units: DisplayUnits) -> String {
        let measurement = Measurement(value: meters, unit: UnitLength.meters)
        switch units {
        case .metric:
            let value = meters >= 1000 ? measurement.converted(to: .kilometers) : measurement
            return value.formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...1))))
        case .imperial:
            let feet = measurement.converted(to: .feet)
            let value = feet.value >= 5280 ? measurement.converted(to: .miles) : feet
            return value.formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...1))))
        }
    }

    /// Bytes as "02 01 06 ...", 16 per line.
    static func hex(_ data: Data) -> String {
        let digits = Array("0123456789ABCDEF")
        var lines: [String] = []
        var line: [String] = []
        for byte in data {
            line.append(String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]]))
            if line.count == 16 {
                lines.append(line.joined(separator: " "))
                line = []
            }
        }
        if !line.isEmpty { lines.append(line.joined(separator: " ")) }
        return lines.joined(separator: "\n")
    }
}
