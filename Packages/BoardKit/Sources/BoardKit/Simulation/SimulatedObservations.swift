import BoardProtocol
import Foundation
import SwiftProtobuf

/// Record generation for one dwell or scan window, aggregated the way the
/// firmware does it: one AP record per BSSID, one client record per MAC and one
/// probe record per (MAC, SSID).
extension SimulatedBoardEngine {
    private static let broadcast = Data(repeating: 0xFF, count: 6)
    /// Beacon interval of every simulated AP, in ms (100 TU).
    private static let beaconIntervalMs = 102.4

    mutating func wifiDwell(channel: UInt32, durationMs: UInt32, endMs: UInt64) -> [NSBRecord] {
        let here = SimulatedWorld.surveyorPosition(atMs: endMs)
        let band = WifiChannels.band(of: channel)
        let link: SimulatedRadio.Link = band == .ghz5 ? .wifi5 : .wifi24
        let frequency = WifiChannels.frequencyMHz(of: channel)
        let enabled = configuration
        var records: [NSBRecord] = []
        var frames = 0

        if enabled.wifiAp {
            for ap in world.accessPoints {
                // 2.4 GHz channels overlap, so beacons from up to two channels away are heard, weaker.
                let offset = abs(Int(ap.channel) - Int(channel))
                guard WifiChannels.band(of: ap.channel) == band, offset == 0 || (band == .ghz24 && offset <= 2) else { continue }
                let beacons = max(1, Int(Double(durationMs) / Self.beaconIntervalMs))
                let mean = SimulatedRadio.meanRSSI(
                    link: link, distance: SimulatedRadio.distance(here, ap.position),
                    shadowing: ap.shadowing, txOffset: -6 * Double(offset)
                )
                guard let sample = SimulatedRadio.sample(mean: mean, count: beacons, rng: &rng) else { continue }
                frames += sample.decoded
                let lastFrameMs = endMs - UInt64.random(in: 0...50, using: &rng)
                let observation = apObservation(ap, sample: sample, timeMs: lastFrameMs)
                records.append(.with { $0.ap = observation })
            }
        }

        for client in world.clients {
            let mean = SimulatedRadio.meanRSSI(link: link, distance: SimulatedRadio.distance(here, client.position), shadowing: client.shadowing)
            let associatedAP = client.associatedAP.map { world.accessPoints[$0] }
            var sourceFlags: UInt32 = 0
            var frameCount = 0
            var sample: (max: Int32, last: Int32, decoded: Int)?

            if let ap = associatedAP, ap.channel == channel, rng.chance(0.75) {
                sample = SimulatedRadio.sample(mean: mean, count: Int.random(in: 1...20, using: &rng), rng: &rng)
                sourceFlags |= UInt32(NSBClientSource.data.rawValue)
                if rng.chance(0.4) { sourceFlags |= UInt32(NSBClientSource.nullData.rawValue) }
                frameCount = sample?.decoded ?? 0
                frames += frameCount
            }

            if rng.chance(client.probeRate), let probeSample = SimulatedRadio.sample(mean: mean, count: 2, rng: &rng) {
                frames += probeSample.decoded
                if enabled.wifiProbes {
                    let ssids = [""] + client.probedSSIDs.filter { _ in rng.chance(0.6) }
                    for ssid in ssids {
                        let observation = probeObservation(client, ssid: ssid, sample: probeSample, channel: channel, timeMs: endMs)
                        records.append(.with { $0.probe = observation })
                    }
                }
                sourceFlags |= UInt32(NSBClientSource.probeReq.rawValue)
                frameCount += probeSample.decoded
                if sample == nil { sample = probeSample }
            }

            guard enabled.wifiClient, let sample, frameCount > 0 else { continue }
            var observation = NSBClientObservation()
            observation.boardTimeMs = boardTime(atUptime: endMs)
            observation.channel = channel
            observation.frequencyMhz = frequency
            observation.band = band
            observation.clientMac = Data(client.mac)
            if let ap = associatedAP, sourceFlags & UInt32(NSBClientSource.data.rawValue) != 0 {
                observation.associatedBssid = Data(ap.bssid)
            }
            observation.rssiMax = sample.max
            observation.rssiLast = sample.last
            observation.noiseFloorDbm = SimulatedRadio.noiseFloor
            observation.frameCount = UInt32(frameCount)
            observation.sourceFlags = sourceFlags
            observation.locallyAdministered = client.mac[0] & 0x02 != 0
            records.append(.with { $0.client = observation })
        }

        countProduced(records: records.count, frames: frames)
        return records
    }

    private func apObservation(_ ap: SimulatedWorld.AccessPoint, sample: (max: Int32, last: Int32, decoded: Int), timeMs: UInt64) -> NSBApObservation {
        var observation = NSBApObservation()
        observation.boardTimeMs = boardTime(atUptime: timeMs)
        observation.channel = ap.channel
        observation.frequencyMhz = WifiChannels.frequencyMHz(of: ap.channel)
        observation.band = WifiChannels.band(of: ap.channel)
        observation.bssid = Data(ap.bssid)
        observation.ssid = ap.hidden ? Data() : Data(ap.ssid.utf8)
        observation.ssidHidden = ap.hidden
        observation.rssiMax = sample.max
        observation.rssiLast = sample.last
        observation.noiseFloorDbm = SimulatedRadio.noiseFloor
        observation.beaconCount = UInt32(sample.decoded)
        observation.beaconIntervalTu = 100
        observation.security = ap.security
        // ESS, plus Privacy for anything but open networks.
        observation.capabilityInfo = 0x0001 | (ap.security == .open || ap.security == .owe ? 0 : 0x0010)
        let rsnCCMP: UInt32 = 0x000F_AC04
        switch ap.security {
        case .wpa:
            observation.groupCipher = 0x0050_F202
            observation.pairwiseCiphers = [0x0050_F202]
            observation.akmSuites = [0x0050_F202]
        case .wpaWpa2, .wpa2:
            observation.groupCipher = rsnCCMP
            observation.pairwiseCiphers = [rsnCCMP]
            observation.akmSuites = [0x000F_AC02]
        case .wpa2Wpa3:
            observation.groupCipher = rsnCCMP
            observation.pairwiseCiphers = [rsnCCMP]
            observation.akmSuites = [0x000F_AC02, 0x000F_AC08]
        case .wpa3:
            observation.groupCipher = rsnCCMP
            observation.pairwiseCiphers = [rsnCCMP]
            observation.akmSuites = [0x000F_AC08]
        case .owe:
            observation.groupCipher = rsnCCMP
            observation.pairwiseCiphers = [rsnCCMP]
            observation.akmSuites = [0x000F_AC12]
        default:
            break
        }
        observation.phyFlags = ap.phyFlags
        observation.channelWidth = ap.width
        observation.wps = ap.wps
        observation.passpoint = ap.passpoint
        // 2.4 GHz radios advertise 1, 2, 5.5 and 11 Mbps as basic; 5 GHz starts at 6 Mbps.
        observation.supportedRates = observation.band == .ghz24
            ? Data([0x82, 0x84, 0x8B, 0x96, 0x0C, 0x12, 0x18, 0x24])
            : Data([0x8C, 0x12, 0x98, 0x24, 0xB0, 0x48, 0x60, 0x6C])
        if observation.band == .ghz24 { observation.extendedSupportedRates = Data([0x30, 0x48, 0x60, 0x6C]) }
        observation.stationCount = ap.stationCount
        observation.channelUtilization = min(255, ap.stationCount * 9)
        return observation
    }

    private func probeObservation(
        _ client: SimulatedWorld.Client, ssid: String, sample: (max: Int32, last: Int32, decoded: Int),
        channel: UInt32, timeMs: UInt64
    ) -> NSBProbeObservation {
        var observation = NSBProbeObservation()
        observation.boardTimeMs = boardTime(atUptime: timeMs)
        observation.channel = channel
        observation.frequencyMhz = WifiChannels.frequencyMHz(of: channel)
        observation.band = WifiChannels.band(of: channel)
        observation.clientMac = Data(client.mac)
        observation.ssid = Data(ssid.utf8)
        observation.rssiMax = sample.max
        observation.rssiLast = sample.last
        observation.noiseFloorDbm = SimulatedRadio.noiseFloor
        observation.count = UInt32(sample.decoded)
        observation.locallyAdministered = client.mac[0] & 0x02 != 0
        observation.destinationAddress = Self.broadcast
        observation.bssid = Self.broadcast
        observation.phyFlags = UInt32(NSBPhyFlag.ht.rawValue | NSBPhyFlag.vht.rawValue)
        return observation
    }

    mutating func bleWindow(endMs: UInt64) -> [NSBRecord] {
        let here = SimulatedWorld.surveyorPosition(atMs: endMs)
        let sniffer = configuration.role == .bleSniffer
        let windowMs = sniffer ? Double(Self.sniffWindowMs) : Double(Self.interleavePeriodMs) * Self.interleaveDutyCycle
        var records: [NSBRecord] = []
        for (index, device) in world.bleDevices.enumerated() {
            // Advertising intervals from 100 ms to 1 s, fixed per device.
            let intervalMs = 100.0 + Double((index * 37) % 10) * 100
            let expected = windowMs / intervalMs
            let adverts = Int(expected) + (rng.chance(expected.truncatingRemainder(dividingBy: 1)) ? 1 : 0)
            guard adverts > 0 else { continue }
            let mean = SimulatedRadio.meanRSSI(link: .ble, distance: SimulatedRadio.distance(here, device.position), shadowing: device.shadowing)
            guard let sample = SimulatedRadio.sample(mean: mean, count: adverts, rng: &rng) else { continue }
            var observation = NSBBleObservation()
            observation.boardTimeMs = boardTime(atUptime: endMs)
            observation.channel = UInt32([37, 38, 39].randomElement(using: &rng)!)
            observation.address = Data(device.address)
            observation.addressType = device.addressType
            observation.rssiMax = sample.max
            observation.rssiLast = sample.last
            observation.count = UInt32(sample.decoded)
            observation.advType = device.advType
            observation.advData = Data(device.advData.prefix(AdvertisingData.maxLegacyLength))
            if let name = AdvertisingData.localName(in: device.advData) { observation.localName = Data(name.utf8) }
            if let company = device.companyID { observation.companyID = UInt32(company) }
            if let txPower = device.txPower { observation.txPower = Int32(txPower) }
            records.append(.with { $0.ble = observation })
        }
        countProduced(records: records.count, frames: records.count)
        return records
    }
}
