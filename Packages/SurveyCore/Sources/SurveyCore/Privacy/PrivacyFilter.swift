import BoardProtocol
import Foundation

/// Drops records before they are stored or sent anywhere.
///
/// - Privacy zones: a record whose location may be inside a zone (distance
///   minus the fix's accuracy within the radius) is dropped, and so is a track
///   point. A record without a location cannot be placed and is kept.
/// - Ignore list: SSIDs match exactly (byte for byte, case-sensitive). BSSIDs
///   match AP BSSIDs, the BSSID a client is associated with, and the BSSID a
///   probe was sent to. MACs and MAC prefixes match every address in a record.
/// - Probe requests for an ignored SSID are dropped too, so a phone's PNL entry
///   for the user's home network is not kept.
public struct PrivacyFilter: Sendable {
    public let zones: [PrivacyZone]
    private let ssids: Set<Data>
    private let bssids: Set<String>
    private let macs: Set<String>
    private let macPrefixes: [String]

    public init(zones: [PrivacyZone] = [], ignoreList: [IgnoreEntry] = []) {
        self.zones = zones.filter { $0.radiusMeters > 0 }
        var ssids = Set<Data>(), bssids = Set<String>(), macs = Set<String>(), prefixes: [String] = []
        for entry in ignoreList {
            switch entry.kind {
            case .ssid:
                if !entry.value.isEmpty { ssids.insert(Data(entry.value.utf8)) }
            case .bssid:
                if let hex = MACAddress.normalizedHex(entry.value) { bssids.insert(hex) }
            case .mac:
                if let hex = MACAddress.normalizedHex(entry.value) { macs.insert(hex) }
            case .macPrefix:
                if let hex = MACAddress.normalizedHex(entry.value) { prefixes.append(hex) }
            }
        }
        self.ssids = ssids
        self.bssids = bssids
        self.macs = macs
        self.macPrefixes = prefixes
    }

    public init(settings: SettingsStore) {
        self.init(zones: settings[Settings.privacyZones], ignoreList: settings[Settings.ignoreList])
    }

    public var isEmpty: Bool {
        zones.isEmpty && ssids.isEmpty && bssids.isEmpty && macs.isEmpty && macPrefixes.isEmpty
    }

    public func isInsideZone(_ point: GeoPoint?) -> Bool {
        guard let point else { return false }
        return zones.contains { $0.contains(point) }
    }

    /// Zone check that accounts for the fix's horizontal accuracy.
    public func isInsideZone(fix sample: LocationSample?) -> Bool {
        guard let sample else { return false }
        return zones.contains { $0.contains(sample.point, accuracy: sample.horizontalAccuracy ?? 0) }
    }

    /// True if the record may be stored.
    public func allows(_ record: NSBRecord.OneOf_Kind, at location: GeoPoint?) -> Bool {
        allows(record, fix: location.map { LocationSample(latitude: $0.latitude, longitude: $0.longitude, timestamp: .distantPast) })
    }

    /// True if the record may be stored, with `location` placing it.
    public func allows(_ record: NSBRecord.OneOf_Kind, fix location: LocationSample?) -> Bool {
        if isInsideZone(fix: location) { return false }
        switch record {
        case .ap(let ap):
            return !ignoresSSID(ap.ssid) && !ignoresBSSID(ap.bssid) && !ignoresAddress(ap.bssid)
        case .client(let client):
            return !ignoresAddress(client.clientMac) && !ignoresBSSID(client.associatedBssid)
                && !ignoresAddress(client.associatedBssid)
        case .probe(let probe):
            return !ignoresAddress(probe.clientMac) && !ignoresSSID(probe.ssid) && !ignoresBSSID(probe.bssid)
        case .ble(let ble):
            return !ignoresAddress(ble.address)
        case .gps:
            return true
        }
    }

    /// True if a raw 802.11 frame may be kept: outside every zone, and none of
    /// its addresses or its SSID element (management frames) is ignored.
    public func allowsRawFrame(_ frame: Data, at location: GeoPoint?) -> Bool {
        allowsRawFrame(frame, fix: location.map { LocationSample(latitude: $0.latitude, longitude: $0.longitude, timestamp: .distantPast) })
    }

    public func allowsRawFrame(_ frame: Data, fix location: LocationSample?) -> Bool {
        if isInsideZone(fix: location) { return false }
        let bytes = [UInt8](frame)
        guard bytes.count >= 10 else { return true }
        let type = (bytes[0] >> 2) & 0x3, subtype = bytes[0] >> 4
        var addresses = [Data(bytes[4..<10])]
        if bytes.count >= 16 { addresses.append(Data(bytes[10..<16])) }
        if type != 1, bytes.count >= 22 { addresses.append(Data(bytes[16..<22])) }
        if addresses.contains(where: { ignoresAddress($0) || ignoresBSSID($0) }) { return false }
        guard type == 0, !ssids.isEmpty else { return true }
        // Where the elements start in management frames that carry an SSID.
        let elementsStart: Int? = switch subtype {
        case 0: 28      // association request
        case 2: 34      // reassociation request
        case 4: 24      // probe request
        case 5, 8: 36   // probe response, beacon
        default: nil
        }
        guard let start = elementsStart, bytes.count >= start + 2, bytes[start] == 0 else { return true }
        let length = Int(bytes[start + 1])
        guard bytes.count >= start + 2 + length else { return true }
        return !ignoresSSID(Data(bytes[(start + 2)..<(start + 2 + length)]))
    }

    private func ignoresSSID(_ ssid: Data) -> Bool {
        !ssid.isEmpty && ssids.contains(ssid)
    }

    private func ignoresBSSID(_ bytes: Data) -> Bool {
        guard !bssids.isEmpty, !bytes.isEmpty else { return false }
        return bssids.contains(Self.hex(bytes))
    }

    private func ignoresAddress(_ bytes: Data) -> Bool {
        guard !bytes.isEmpty, !(macs.isEmpty && macPrefixes.isEmpty) else { return false }
        let hex = Self.hex(bytes)
        return macs.contains(hex) || macPrefixes.contains { hex.hasPrefix($0) }
    }

    private static func hex(_ bytes: Data) -> String {
        MACAddress.string(bytes).replacingOccurrences(of: ":", with: "")
    }
}
