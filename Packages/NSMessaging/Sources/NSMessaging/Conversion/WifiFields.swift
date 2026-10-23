import BoardProtocol
import Foundation

/// Field derivations shared by the Wi-Fi converters and the file writers.
public enum WifiFields {
    static let rsnOUI: UInt32 = 0x000FAC
    static let wpaOUI: UInt32 = 0x0050F2

    /// `aa:bb:cc:dd:ee:ff` (Wi-Fi, lowercase as Android's ScanResult) or uppercase
    /// (Bluetooth, as Android's BluetoothDevice). Empty for anything but 6 bytes.
    public static func mac(_ bytes: Data, uppercase: Bool = false) -> String {
        guard bytes.count == 6 else { return "" }
        return bytes.map { String(format: uppercase ? "%02X" : "%02x", $0) }.joined(separator: ":")
    }

    /// The locally administered bit (0x02 of the first byte).
    public static func isLocallyAdministered(_ bytes: Data) -> Bool {
        guard let first = bytes.first else { return false }
        return first & 0x02 != 0
    }

    /// The SSID as text: empty when hidden, invalid UTF-8 becomes U+FFFD.
    public static func ssid(_ bytes: Data) -> String {
        if bytes.allSatisfy({ $0 == 0 }) { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Supported Rates octets as NS text: "1; 2; 5.5; 11". Membership
    /// selectors (basic bit plus values 121 to 127) are not rates and are skipped.
    public static func rates(_ octets: Data) -> String {
        octets.compactMap { octet -> String? in
            let value = Int(octet & 0x7F)
            if octet & 0x80 != 0 && value >= 121 { return nil }
            return value % 2 == 0 ? String(value / 2) : "\(value / 2).5"
        }.joined(separator: "; ")
    }

    public static func cipherSuite(_ selector: UInt32) -> CipherSuite? {
        let oui = selector >> 8
        let type = selector & 0xFF
        switch (oui, type) {
        case (_, 0) where oui == rsnOUI || oui == wpaOUI: return nil // "use group cipher"
        case (rsnOUI, 1), (wpaOUI, 1): return .wep40
        case (rsnOUI, 2), (wpaOUI, 2): return .tkip
        case (rsnOUI, 4), (wpaOUI, 4): return .ccmp
        case (rsnOUI, 5), (wpaOUI, 5): return .wep104
        case (rsnOUI, 8): return .gcmp128
        case (rsnOUI, 9): return .gcmp256
        case (rsnOUI, 10): return .ccmp256
        case (rsnOUI, 11): return .bipGmac128
        case (rsnOUI, 12): return .bipGmac256
        case (rsnOUI, 13): return .bipCmac256
        default: return .unknown
        }
    }

    public static func akmSuite(_ selector: UInt32) -> AkmSuite {
        switch (selector >> 8, selector & 0xFF) {
        case (rsnOUI, 1), (wpaOUI, 1): .ieee8021x
        case (rsnOUI, 2), (wpaOUI, 2): .psk
        case (rsnOUI, 3): .ftIeee8021x
        case (rsnOUI, 4): .ftPsk
        case (rsnOUI, 5): .ieee8021xSha256
        case (rsnOUI, 6): .pskSha256
        case (rsnOUI, 7): .tdls
        case (rsnOUI, 8): .sae
        case (rsnOUI, 9): .ftSae
        default: .unknown
        }
    }

    /// The board's security summary as an NS encryption type. OWE has no NS
    /// value and maps to UNKNOWN; enterprise networks are already in the WPA2
    /// or WPA3 bucket (the AKM list tells them apart).
    public static func encryptionType(_ security: NSBSecurityType) -> EncryptionType {
        switch security {
        case .open: .open
        case .wep: .wep
        case .wpa: .wpa
        case .wpaWpa2: .wpaWpa2
        case .wpa2: .wpa2
        case .wpa3: .wpa3
        case .wpa2Wpa3: .wpa2Wpa3
        case .owe, .unknown, .UNRECOGNIZED: .unknown
        }
    }

    /// Pairwise ciphers then the group cipher, without repeats. Open and WEP
    /// networks (no RSN or WPA element) report OPEN or WEP.
    public static func cipherSuites(_ ap: NSBApObservation) -> [CipherSuite] {
        switch ap.security {
        case .open: return [.open]
        case .wep: return [.wep]
        default: break
        }
        var result: [CipherSuite] = []
        for selector in ap.pairwiseCiphers + [ap.groupCipher] where selector != 0 {
            if let suite = cipherSuite(selector), !result.contains(suite) { result.append(suite) }
        }
        return result
    }

    public static func akmSuites(_ ap: NSBApObservation) -> [AkmSuite] {
        if ap.security == .open { return [.open] }
        var result: [AkmSuite] = []
        for selector in ap.akmSuites {
            let suite = akmSuite(selector)
            if !result.contains(suite) { result.append(suite) }
        }
        return result
    }

    public static func serviceSetType(capabilityInfo: UInt32) -> ServiceSetType {
        switch (capabilityInfo & 0x0001 != 0, capabilityInfo & 0x0002 != 0) {
        case (true, false): .ess
        case (false, true): .ibss
        default: .unknown
        }
    }

    public static func bandwidth(_ width: NSBChannelWidth, phyFlags: UInt32) -> WifiBandwidth {
        switch width {
        case .mhz20: return .mhz20
        case .mhz40: return .mhz40
        case .mhz80: return .mhz80
        case .mhz160: return .mhz160
        case .mhz80P80: return .mhz80Plus
        case .mhz320: return .mhz320
        case .unknown, .UNRECOGNIZED:
            // Without HT or later capabilities an AP can only use 20 MHz.
            return phyFlags == 0 ? .mhz20 : .unknown
        }
    }

    private static let cckRates: Set<UInt8> = [2, 4, 11, 22]
    private static let ofdmRates: Set<UInt8> = [12, 18, 24, 36, 48, 72, 96, 108]

    /// The newest standard whose capability element was present. Legacy 2.4 GHz
    /// networks are told apart by their rates (CCK only b, OFDM only g, both bg).
    public static func standard(phyFlags: UInt32, band: NSBBand, rates: Data = Data()) -> WifiStandard {
        if phyFlags & UInt32(NSBPhyFlag.eht.rawValue) != 0 { return .ieee80211be }
        if phyFlags & UInt32(NSBPhyFlag.he.rawValue) != 0 { return .ieee80211ax }
        if phyFlags & UInt32(NSBPhyFlag.vht.rawValue) != 0 && band == .ghz5 { return .ieee80211ac }
        if phyFlags & UInt32(NSBPhyFlag.ht.rawValue | NSBPhyFlag.vht.rawValue) != 0 { return .ieee80211n }
        switch band {
        case .ghz5: return .ieee80211a
        case .ghz24:
            let values = Set(rates.map { $0 & 0x7F })
            switch (!values.isDisjoint(with: cckRates), !values.isDisjoint(with: ofdmRates)) {
            case (true, true): return .ieee80211bg
            case (true, false): return .ieee80211b
            case (false, true): return .ieee80211g
            case (false, false): return .unknown
            }
        default: return .unknown
        }
    }

    /// Station frame types from ClientObservation.source_flags.
    public static func frameTypes(sourceFlags: UInt32) -> [StationFrameType] {
        let bits: [(NSBClientSource, StationFrameType)] = [
            (.data, .data), (.nullData, .nullData), (.probeReq, .probeRequest),
            (.assocReq, .associationRequest), (.reassocReq, .reassociationRequest),
            (.auth, .authentication), (.action, .action),
        ]
        return bits.filter { sourceFlags & UInt32($0.0.rawValue) != 0 }.map(\.1)
    }
}
