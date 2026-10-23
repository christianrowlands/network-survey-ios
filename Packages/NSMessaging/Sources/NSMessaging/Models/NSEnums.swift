/// An NS Messaging enum. JSON carries the value name; `unknown` (number 0) is
/// the proto default and is left out of the JSON. Names this version does not
/// know decode as `unknown`.
public protocol NSEnum: RawRepresentable, CaseIterable, Sendable, Codable, Hashable where RawValue == String {
    static var unknown: Self { get }
}

extension NSEnum {
    public init(from decoder: Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: name) ?? .unknown
    }
}

public enum ServiceSetType: String, NSEnum {
    case unknown = "UNKNOWN", bss = "BSS", ess = "ESS", bssEss = "BSS_ESS", ibss = "IBSS", mbss = "MBSS"
}

public enum CipherSuite: String, NSEnum {
    case unknown = "UNKNOWN", wep40 = "WEP_40", tkip = "TKIP", ccmp = "CCMP", wep104 = "WEP_104"
    case gcmp128 = "GCMP_128", gcmp256 = "GCMP_256", ccmp256 = "CCMP_256"
    case bipGmac128 = "BIP_GMAC_128", bipGmac256 = "BIP_GMAC_256", bipCmac256 = "BIP_CMAC_256"
    case open = "OPEN", wep = "WEP"
}

public enum AkmSuite: String, NSEnum {
    case unknown = "UNKNOWN", ieee8021x = "IEEE_8021X", ftIeee8021x = "FT_IEEE_8021X"
    case ieee8021xSha256 = "IEEE_8021X_SHA256", psk = "PSK", ftPsk = "FT_PSK", pskSha256 = "PSK_SHA256"
    case sae = "SAE", ftSae = "FT_SAE", tdls = "TDLS", open = "OPEN"
}

public enum EncryptionType: String, NSEnum {
    case unknown = "UNKNOWN", open = "OPEN", wep = "WEP", wpa = "WPA", wpaWpa2 = "WPA_WPA2"
    case wpa2 = "WPA2", wpa3 = "WPA3", wpa2Wpa3 = "WPA2_WPA3"
}

public enum NodeType: String, NSEnum {
    case unknown = "UNKNOWN", ap = "AP", nonApSta = "NON_AP_STA", sta = "STA"
}

public enum WifiStandard: String, NSEnum {
    case unknown = "UNKNOWN", ieee80211 = "IEEE80211", ieee80211a = "IEEE80211A", ieee80211b = "IEEE80211B"
    case ieee80211g = "IEEE80211G", ieee80211bg = "IEEE80211BG", ieee80211n = "IEEE80211N"
    case ieee80211ac = "IEEE80211AC", ieee80211ax = "IEEE80211AX", ieee80211be = "IEEE80211BE"
}

public enum WifiBandwidth: String, NSEnum {
    case unknown = "UNKNOWN", mhz20 = "MHZ_20", mhz40 = "MHZ_40", mhz80 = "MHZ_80"
    case mhz80Plus = "MHZ_80_PLUS", mhz160 = "MHZ_160", mhz320 = "MHZ_320"
}

public enum BluetoothTechnology: String, NSEnum {
    case unknown = "UNKNOWN", brEdr = "BR_EDR", le = "LE"
}

public enum BluetoothSupportedTechnologies: String, NSEnum {
    case unknown = "UNKNOWN", brEdr = "BR_EDR", le = "LE", dual = "DUAL"
}

public enum BluetoothAddressType: String, NSEnum {
    case unknown = "UNKNOWN", `public` = "PUBLIC", random = "RANDOM", anonymous = "ANONYMOUS"
}

/// Experimental, not in NS Messaging 2.6.0: the frame types a station sent.
public enum StationFrameType: String, NSEnum {
    case unknown = "UNKNOWN", data = "DATA", nullData = "NULL_DATA", probeRequest = "PROBE_REQUEST"
    case associationRequest = "ASSOCIATION_REQUEST", reassociationRequest = "REASSOCIATION_REQUEST"
    case authentication = "AUTHENTICATION", action = "ACTION"
}
