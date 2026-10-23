import BoardProtocol
import Foundation

extension WifiBeaconRecord {
    /// One AP observation (one BSSID per channel dwell) as a beacon record.
    /// Signal strength is the strongest frame of the dwell.
    public init(ap: NSBApObservation, context: RecordContext) {
        var data = WifiBeaconRecordData()
        data.apply(context)
        let bssid = WifiFields.mac(ap.bssid)
        data.bssid = bssid
        data.sourceAddress = bssid
        data.destinationAddress = "ff:ff:ff:ff:ff:ff"
        data.ssid = ap.ssidHidden ? "" : WifiFields.ssid(ap.ssid)
        if ap.hasBeaconIntervalTu { data.beaconInterval = Int32(clamping: ap.beaconIntervalTu) }
        data.serviceSetType = WifiFields.serviceSetType(capabilityInfo: ap.capabilityInfo)
        data.supportedRates = WifiFields.rates(ap.supportedRates)
        data.extendedSupportedRates = WifiFields.rates(ap.extendedSupportedRates)
        data.cipherSuites = WifiFields.cipherSuites(ap)
        data.akmSuites = WifiFields.akmSuites(ap)
        data.encryptionType = WifiFields.encryptionType(ap.security)
        data.wps = ap.wps
        if ap.passpoint { data.passpoint = true }
        data.bandwidth = WifiFields.bandwidth(ap.channelWidth, phyFlags: ap.phyFlags)
        if ap.channel != 0 { data.channel = Int32(clamping: ap.channel) }
        if ap.frequencyMhz != 0 { data.frequencyMhz = Int32(clamping: ap.frequencyMhz) }
        data.signalStrength = Float(ap.rssiMax)
        if ap.hasNoiseFloorDbm { data.snr = Float(ap.rssiMax - ap.noiseFloorDbm) }
        data.nodeType = .ap
        data.standard = WifiFields.standard(
            phyFlags: ap.phyFlags, band: ap.band, rates: ap.supportedRates + ap.extendedSupportedRates
        )
        self.init(data: data)
    }
}

extension WifiProbeRequestRecord {
    /// One probe observation (one client MAC and SSID per channel dwell).
    public init(probe: NSBProbeObservation, context: RecordContext) {
        var data = WifiProbeRequestRecordData()
        data.apply(context)
        data.sourceAddress = WifiFields.mac(probe.clientMac)
        data.destinationAddress = WifiFields.mac(probe.destinationAddress)
        data.bssid = WifiFields.mac(probe.bssid)
        data.ssid = WifiFields.ssid(probe.ssid)
        if probe.channel != 0 { data.channel = Int32(clamping: probe.channel) }
        if probe.frequencyMhz != 0 { data.frequencyMhz = Int32(clamping: probe.frequencyMhz) }
        data.signalStrength = Float(probe.rssiMax)
        if probe.hasNoiseFloorDbm { data.snr = Float(probe.rssiMax - probe.noiseFloorDbm) }
        data.nodeType = .nonApSta
        // No rates in a probe observation, so a legacy 2.4 GHz probe stays UNKNOWN.
        data.standard = WifiFields.standard(phyFlags: probe.phyFlags, band: probe.band)
        self.init(data: data)
    }
}

extension WifiStationRecord {
    /// Experimental: one client observation (one station MAC per channel dwell).
    public init(client: NSBClientObservation, context: RecordContext) {
        var data = WifiStationRecordData()
        data.apply(context)
        data.sourceAddress = WifiFields.mac(client.clientMac)
        data.bssid = WifiFields.mac(client.associatedBssid)
        if client.channel != 0 { data.channel = Int32(clamping: client.channel) }
        if client.frequencyMhz != 0 { data.frequencyMhz = Int32(clamping: client.frequencyMhz) }
        data.signalStrength = Float(client.rssiMax)
        if client.hasNoiseFloorDbm { data.snr = Float(client.rssiMax - client.noiseFloorDbm) }
        data.frameCount = Int32(clamping: client.frameCount)
        data.frameTypes = WifiFields.frameTypes(sourceFlags: client.sourceFlags)
        data.locallyAdministered = client.locallyAdministered
        self.init(data: data)
    }
}
