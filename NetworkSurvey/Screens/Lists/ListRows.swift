import SurveyCore
import SwiftUI

struct AccessPointRowView: View {
    let ap: AccessPointRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(DataFormat.ssid(ap.ssid, hidden: ap.ssidHidden))
                    .font(Theme.Fonts.rowTitle.weight(.medium))
                    .foregroundStyle(ap.ssid?.isEmpty == false ? Theme.Colors.ink : Theme.Colors.ink2)
                    .lineLimit(1)
                Text(ap.bssid)
                    .font(Theme.Fonts.mono)
                    .foregroundStyle(Theme.Colors.ink2)
                TagRow {
                    TagPill(text: DataFormat.security(ap.security), color: DataFormat.securityColor(ap.security))
                    BandTag(band: ap.band, channel: ap.channel)
                    if ap.ssidHidden { TagPill(text: "Hidden", color: Theme.Colors.tagHidden) }
                }
            }
            Spacer(minLength: Theme.Spacing.s)
            SignalColumn(rssi: ap.rssiLast, lastSeen: ap.lastSeen)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .combine)
    }
}

struct ClientRowView: View {
    let item: ClientListItem

    var body: some View {
        let client = item.client
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(client.mac)
                    .font(Theme.Fonts.mono)
                    .foregroundStyle(Theme.Colors.ink)
                Group {
                    if let bssid = client.associatedBssid {
                        if let ssid = item.associatedSSID, !ssid.isEmpty {
                            Text("Connected to \(ssid)")
                        } else {
                            Text("Connected to \(bssid)")
                        }
                    } else {
                        Text("Not connected")
                    }
                }
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Colors.ink2)
                .lineLimit(2)
                TagRow {
                    if client.band > 0 { BandTag(band: client.band, channel: client.channel) }
                    if client.randomized { RandomizedBadge() }
                }
            }
            Spacer(minLength: Theme.Spacing.s)
            SignalColumn(rssi: client.rssiLast, lastSeen: client.lastSeen)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .combine)
    }
}

struct ProbeNetworkRowView: View {
    let network: ProbeNetworkRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(DataFormat.probedNetwork(network.ssid))
                    .font(Theme.Fonts.rowTitle.weight(.medium))
                    .foregroundStyle(network.isWildcard ? Theme.Colors.ink2 : Theme.Colors.ink)
                    .lineLimit(1)
                Text("\(DataFormat.count(network.clientCount, "client")) · \(DataFormat.count(network.frameCount, "request"))")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.ink2)
                if network.accessPointCount > 0 {
                    TagPill(text: "AP seen", color: Theme.Colors.wifi)
                        .accessibilityLabel("An access point with this name was seen")
                }
            }
            Spacer(minLength: Theme.Spacing.s)
            SignalColumn(rssi: network.rssiLast, lastSeen: network.lastSeen)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .combine)
    }
}

struct ProbeClientRowView: View {
    let client: ProbeClientRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(client.mac)
                    .font(Theme.Fonts.mono)
                    .foregroundStyle(Theme.Colors.ink)
                Text(networks)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.ink2)
                    .lineLimit(2)
                if client.randomized {
                    RandomizedBadge()
                }
            }
            Spacer(minLength: Theme.Spacing.s)
            SignalColumn(rssi: client.rssiLast, lastSeen: client.lastSeen)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    /// The first few network names, then how many more.
    private var networks: String {
        let shown = 3
        guard !client.ssids.isEmpty else { return "Wildcard probes only" }
        var names = client.ssids.prefix(shown).joined(separator: ", ")
        if client.ssids.count > shown { names += " and \(client.ssids.count - shown) more" }
        return "Looked for \(names)"
    }
}

struct BLERowView: View {
    let device: BLEDeviceRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(device.name?.isEmpty == false ? device.name! : "Unnamed device")
                    .font(Theme.Fonts.rowTitle.weight(.medium))
                    .foregroundStyle(device.name?.isEmpty == false ? Theme.Colors.ink : Theme.Colors.ink2)
                    .lineLimit(1)
                Text(device.address)
                    .font(Theme.Fonts.mono)
                    .foregroundStyle(Theme.Colors.ink2)
                TagRow {
                    if let company = device.companyId {
                        TagPill(text: BLECompanies.name(for: company) ?? BLECompanies.hexID(company), color: Theme.Colors.bluetooth)
                    }
                    if DataFormat.isPrivateBLEAddress(device.address, addressType: device.addressType) { RandomizedBadge() }
                }
            }
            Spacer(minLength: Theme.Spacing.s)
            SignalColumn(rssi: device.rssiLast, lastSeen: device.lastSeen)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .combine)
    }
}

/// Tags that wrap to a second line at large text sizes.
struct TagRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.xs) { content }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) { content }
        }
    }
}

struct RandomizedBadge: View {
    var body: some View {
        TagPill(text: "Randomized", color: Theme.Colors.tagRandomized)
            .accessibilityLabel("Randomized MAC address")
    }
}

struct BandTag: View {
    let band: Int
    let channel: Int

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Dot(color: DataFormat.bandColor(band), size: 6)
            Text(channel > 0 ? "\(DataFormat.band(band)), ch \(channel)" : DataFormat.band(band))
        }
        .font(Theme.Fonts.tag)
        .foregroundStyle(Theme.Colors.ink2)
        .padding(.horizontal, Theme.Spacing.s - 2)
        .padding(.vertical, Theme.Spacing.xxs)
        .background(Theme.Colors.panelHigh, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(channel > 0 ? "\(DataFormat.band(band)), channel \(channel)" : DataFormat.band(band))
    }
}

/// The last RSSI and how long ago, right-aligned.
struct SignalColumn: View {
    let rssi: Int
    let lastSeen: Date

    var body: some View {
        VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
            Text(DataFormat.dBm(rssi))
                .font(Theme.Fonts.counter.weight(.semibold))
                .foregroundStyle(Theme.Colors.signal(Int32(clamping: rssi)))
            TimelineView(.periodic(from: .now, by: 5)) { context in
                Text(DataFormat.ago(lastSeen, now: context.date))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.ink2)
            }
        }
        .fixedSize()
    }
}
