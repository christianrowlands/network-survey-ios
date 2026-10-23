import BoardProtocol
import Foundation

/// A synthetic radio neighbourhood shared by all simulated boards: access points,
/// Wi-Fi clients and BLE devices placed in a 200 m x 120 m area, plus the path
/// the surveyor walks. Everything is derived from the seed.
///
/// All identifiers are fake: universally administered addresses come from the
/// IANA documentation block 00:00:5E:00:53:xx (RFC 7042), the rest are locally
/// administered or random BLE addresses. SSIDs are made up.
public struct SimulatedWorld: Sendable {
    public struct Point: Sendable, Equatable {
        public var x: Double
        public var y: Double
    }

    public struct AccessPoint: Sendable {
        public var bssid: [UInt8]
        public var ssid: String
        public var hidden: Bool
        public var channel: UInt32
        public var width: NSBChannelWidth
        public var security: NSBSecurityType
        public var phyFlags: UInt32
        public var wps: Bool
        public var passpoint: Bool
        public var stationCount: UInt32
        public var position: Point
        /// Fixed shadowing for this AP in dB (walls, height).
        public var shadowing: Double
    }

    public struct Client: Sendable {
        public var mac: [UInt8]
        public var randomized: Bool
        /// Index into `accessPoints`, or nil when the client is not associated.
        public var associatedAP: Int?
        /// Preferred network list, used for directed probes.
        public var probedSSIDs: [String]
        /// Chance the client sends probes during one dwell on a channel.
        public var probeRate: Double
        public var position: Point
        public var shadowing: Double
    }

    public struct BLEDevice: Sendable {
        public var address: [UInt8]
        public var addressType: NSBBleAddressType
        public var advType: NSBBleAdvType
        public var name: String
        public var companyID: UInt16?
        public var serviceUUIDs: [UInt16]
        public var txPower: Int8?
        public var advData: [UInt8]
        public var position: Point
        public var shadowing: Double
    }

    public static let width = 200.0
    public static let height = 120.0

    public let seed: UInt64
    public private(set) var accessPoints: [AccessPoint] = []
    public private(set) var clients: [Client] = []
    public private(set) var bleDevices: [BLEDevice] = []

    public init(seed: UInt64, accessPoints apCount: Int = 64, clients clientCount: Int = 90, bleDevices bleCount: Int = 40) {
        self.seed = seed
        var macs = MACFactory()
        var rng = SeededGenerator(seed: seed).derived(1)
        accessPoints = Self.makeAccessPoints(count: apCount, macs: &macs, rng: &rng)
        var clientRNG = SeededGenerator(seed: seed).derived(2)
        clients = Self.makeClients(count: clientCount, aps: accessPoints, macs: &macs, rng: &clientRNG)
        var bleRNG = SeededGenerator(seed: seed).derived(3)
        bleDevices = Self.makeBLEDevices(count: bleCount, macs: &macs, rng: &bleRNG)
    }

    /// Where the surveyor (and so every board) is at `timeMs` after the start:
    /// a slow loop around the area with some wobble, about 1.3 m/s.
    public static func surveyorPosition(atMs timeMs: UInt64) -> Point {
        let t = Double(timeMs) / 1000
        let phase = 2 * Double.pi * t / 360
        return Point(
            x: width / 2 + 80 * cos(phase) + 4 * sin(phase * 7),
            y: height / 2 + 45 * sin(phase) + 3 * cos(phase * 5)
        )
    }

    // MARK: - Generation

    private static let ssidNames = [
        "ExampleNet", "Cafe-Guest", "Library-Public", "HomeNet", "Office-Corp", "Printer-Setup",
        "IoT-Devices", "Bistro-WiFi", "Transit-Free", "Hotel-Lobby", "TestLab", "Studio-5",
        "Garden-AP", "Clinic-Guest", "Warehouse", "Campus-Open", "Bookshop", "Gym-Members",
    ]

    private static let preferredSSIDs = [
        "HomeNet", "ExampleNet", "Airport-Free", "Hotel-Lobby", "Office-Corp", "Cafe-Guest",
        "Family-Room", "Train-WiFi", "Conference-2026", "Neighbour-Net",
    ]

    private static func makeAccessPoints(count: Int, macs: inout MACFactory, rng: inout SeededGenerator) -> [AccessPoint] {
        let channels24: [UInt32] = [1, 1, 1, 6, 6, 6, 6, 11, 11, 11, 3, 4, 9]
        let channels5: [UInt32] = [36, 40, 44, 48, 52, 100, 112, 149, 153, 157, 161]
        var aps: [AccessPoint] = []
        while aps.count < count {
            let name = ssidNames.randomElement(using: &rng)!
            let ssid = rng.chance(0.4) ? "\(name)-\(String(format: "%04X", UInt16.random(in: 0...0xFFFF, using: &rng)))" : name
            let position = Point(x: .random(in: 0...width, using: &rng), y: .random(in: 0...height, using: &rng))
            let security = securityType(rng: &rng, ssid: ssid)
            let hidden = rng.chance(0.08)
            // Many sites run one radio per band with the same SSID.
            let dualBand = rng.chance(0.55)
            let base = macs.universal()
            let radios: [(UInt32, Bool)] = dualBand
                ? [(channels24.randomElement(using: &rng)!, false), (channels5.randomElement(using: &rng)!, true)]
                : [rng.chance(0.6) ? (channels24.randomElement(using: &rng)!, false) : (channels5.randomElement(using: &rng)!, true)]
            for (index, radio) in radios.enumerated() where aps.count < count {
                var bssid = base
                bssid[5] &+= UInt8(index * 16)
                if index > 0 { bssid[0] |= 0x02 }  // Second radio uses a locally administered BSSID.
                let is5 = radio.1
                let phy = NSBPhyFlag.ht.rawValue | (is5 ? NSBPhyFlag.vht.rawValue : 0) | (rng.chance(0.5) ? NSBPhyFlag.he.rawValue : 0)
                aps.append(AccessPoint(
                    bssid: bssid, ssid: ssid, hidden: hidden, channel: radio.0,
                    width: is5 ? (rng.chance(0.6) ? .mhz80 : .mhz40) : .mhz20,
                    security: security, phyFlags: UInt32(phy), wps: rng.chance(0.15),
                    passpoint: ssid.hasPrefix("Transit") || ssid.hasPrefix("Campus"),
                    stationCount: UInt32.random(in: 0...24, using: &rng),
                    position: Point(x: position.x + Double(index), y: position.y),
                    shadowing: rng.noise(sigma: 4)
                ))
            }
        }
        return aps
    }

    private static func securityType(rng: inout SeededGenerator, ssid: String) -> NSBSecurityType {
        if ssid.contains("Guest") || ssid.contains("Free") || ssid.contains("Public") {
            return rng.chance(0.7) ? .open : .owe
        }
        let roll = Double.random(in: 0..<1, using: &rng)
        switch roll {
        case ..<0.04: return .wep
        case ..<0.08: return .wpa
        case ..<0.18: return .wpaWpa2
        case ..<0.62: return .wpa2
        case ..<0.78: return .wpa2Wpa3
        case ..<0.92: return .wpa3
        default: return .open
        }
    }

    private static func makeClients(count: Int, aps: [AccessPoint], macs: inout MACFactory, rng: inout SeededGenerator) -> [Client] {
        (0..<count).map { _ in
            let randomized = rng.chance(0.65)
            let associated = rng.chance(0.6) && !aps.isEmpty ? Int.random(in: 0..<aps.count, using: &rng) : nil
            let position: Point
            if let ap = associated {
                position = Point(x: aps[ap].position.x + rng.noise(sigma: 12), y: aps[ap].position.y + rng.noise(sigma: 12))
            } else {
                position = Point(x: .random(in: 0...width, using: &rng), y: .random(in: 0...height, using: &rng))
            }
            let pnlSize = Int.random(in: 0...3, using: &rng)
            return Client(
                mac: randomized ? macs.randomized(rng: &rng) : macs.universal(),
                randomized: randomized,
                associatedAP: associated,
                probedSSIDs: Array(preferredSSIDs.shuffled(using: &rng).prefix(pnlSize)),
                probeRate: associated == nil ? 0.12 : 0.02,
                position: position,
                shadowing: rng.noise(sigma: 5)
            )
        }
    }

    private static let bleKinds: [(name: String, company: UInt16?, services: [UInt16], advType: NSBBleAdvType)] = [
        ("Fitness-Band", 0x0059, [0x180D, 0x180F], .advInd),
        ("Smart-Bulb", 0x0075, [], .advNonconnInd),
        ("Headphones", 0x004C, [], .advInd),
        ("Keyboard", 0x0006, [0x1812], .advInd),
        ("Thermometer", nil, [0x1809, 0x180F], .advInd),
        ("", 0x004C, [], .advNonconnInd),  // Nameless phone or tag beacon.
        ("", 0x00E0, [0xFE9F], .advNonconnInd),
        ("Door-Sensor", 0x0059, [0x180F], .advScanInd),
        ("Speaker", nil, [0x110B], .extended),
    ]

    private static func makeBLEDevices(count: Int, macs: inout MACFactory, rng: inout SeededGenerator) -> [BLEDevice] {
        (0..<count).map { index in
            let kind = bleKinds.randomElement(using: &rng)!
            let addressType: NSBBleAddressType = rng.chance(0.15) ? .public : .random
            let address = addressType == .public ? macs.universal() : macs.bleRandom(rng: &rng)
            let name = kind.name.isEmpty ? "" : "\(kind.name)-\(index + 1)"
            let txPower: Int8? = rng.chance(0.4) ? Int8.random(in: -12...4, using: &rng) : nil
            let payload = rng.bytes(Int.random(in: 2...8, using: &rng))
            return BLEDevice(
                address: address, addressType: addressType, advType: kind.advType, name: name,
                companyID: kind.company, serviceUUIDs: kind.services, txPower: txPower,
                advData: AdvertisingData.build(
                    name: name, serviceUUIDs: kind.services, txPower: txPower,
                    manufacturer: kind.company.map { ($0, payload) }
                ),
                position: Point(x: .random(in: 0...width, using: &rng), y: .random(in: 0...height, using: &rng)),
                shadowing: rng.noise(sigma: 4)
            )
        }
    }
}

/// Hands out fake MAC addresses without repeats.
struct MACFactory {
    private var nextDocumentation: UInt16 = 0
    private var nextLocal: UInt32 = 0

    /// A universally administered-looking address. The 256 addresses of the
    /// documentation block come first, then locally administered 02:00:5E:xx:xx:xx.
    mutating func universal() -> [UInt8] {
        if nextDocumentation < 256 {
            defer { nextDocumentation += 1 }
            return [0x00, 0x00, 0x5E, 0x00, 0x53, UInt8(nextDocumentation)]
        }
        defer { nextLocal += 1 }
        return [0x02, 0x00, 0x5E, UInt8((nextLocal >> 16) & 0xFF), UInt8((nextLocal >> 8) & 0xFF), UInt8(nextLocal & 0xFF)]
    }

    /// A randomized (locally administered, unicast) client MAC.
    mutating func randomized(rng: inout SeededGenerator) -> [UInt8] {
        var mac = rng.bytes(6)
        mac[0] = (mac[0] & 0xFC) | 0x02
        return mac
    }

    /// A BLE random address: static (top bits 11) or resolvable private (top bits 01).
    mutating func bleRandom(rng: inout SeededGenerator) -> [UInt8] {
        var address = rng.bytes(6)
        address[0] = rng.chance(0.5) ? (address[0] | 0xC0) : ((address[0] & 0x3F) | 0x40)
        return address
    }
}
