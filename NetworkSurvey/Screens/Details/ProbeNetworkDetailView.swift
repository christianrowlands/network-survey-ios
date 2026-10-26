import SurveyCore
import SwiftUI

/// A network name from probe requests: the clients that looked for it and
/// any access points heard advertising it.
struct ProbeNetworkDetailView: View {
    let sessionID: String
    let ssid: String

    var body: some View {
        LiveDetail(query: { [sessionID, ssid] store in
            store.observe { try StoreQueries.probeNetworkDetail($0, sessionID: sessionID, ssid: ssid) }
        }) { detail in
            ProbeNetworkDetailContent(sessionID: sessionID, detail: detail)
        }
        .navigationTitle("Probed network")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !ssid.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    IgnoreMenu(choices: [IgnoreChoice(kind: .ssid, value: ssid, title: "Ignore every \(ssid) network (SSID)")])
                }
            }
        }
    }
}

private struct ProbeNetworkDetailContent: View {
    let sessionID: String
    let detail: ProbeNetworkDetail

    var body: some View {
        let network = detail.network
        List {
            Group {
                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Text(DataFormat.probedNetwork(network.ssid))
                            .font(Theme.Fonts.screenTitle)
                            .foregroundStyle(network.isWildcard ? Theme.Colors.ink2 : Theme.Colors.ink)
                            .textSelection(.enabled)
                            .accessibilityAddTraits(.isHeader)
                        Text("\(DataFormat.count(network.clientCount, "client")) looked for \(network.isWildcard ? "any network" : "this network")")
                            .font(Theme.Fonts.body)
                            .foregroundStyle(Theme.Colors.ink2)
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                } footer: {
                    if network.isWildcard {
                        Text("A wildcard probe request names no network. Any nearby access point may answer it.")
                    } else {
                        Text("Devices send probe requests for the networks they have saved, even when that network is not nearby.")
                    }
                }
                if !network.isWildcard {
                    accessPoints
                }
                clients
                Section("Observations") {
                    DetailRow(label: "Clients", value: DataFormat.count(network.clientCount))
                    DetailRow(label: "Probe requests", value: DataFormat.count(network.frameCount))
                    DetailRow(label: "Strongest last signal", value: DataFormat.dBm(network.rssiLast))
                    DetailRow(label: "First seen", value: DataFormat.dateTime(network.firstSeen))
                    DetailRow(label: "Last seen", value: DataFormat.dateTime(network.lastSeen))
                }
            }
            .panelRows()
        }
        .themedList()
        .listStyle(.insetGrouped)
    }

    private var accessPoints: some View {
        Section("Access points with this name") {
            if detail.accessPoints.isEmpty {
                Text("No access point with this name was heard in this survey.")
                    .foregroundStyle(Theme.Colors.ink2)
            } else {
                ForEach(detail.accessPoints, id: \.bssid) { ap in
                    NavigationLink(value: DetailRoute.accessPoint(sessionID: sessionID, bssid: ap.bssid)) {
                        HStack {
                            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                Text(ap.bssid).font(Theme.Fonts.mono)
                                TagRow {
                                    TagPill(text: DataFormat.security(ap.security), color: DataFormat.securityColor(ap.security))
                                    BandTag(band: ap.band, channel: ap.channel)
                                }
                            }
                            Spacer()
                            signal(ap.rssiLast)
                        }
                    }
                }
            }
        }
    }

    private var clients: some View {
        Section {
            ForEach(detail.clients, id: \.clientMac) { probe in
                NavigationLink(value: DetailRoute.client(sessionID: sessionID, mac: probe.clientMac)) {
                    HStack {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            HStack {
                                Text(probe.clientMac).font(Theme.Fonts.mono)
                                if probe.randomized { RandomizedBadge() }
                            }
                            Text(DataFormat.count(probe.frameCount, "request"))
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.Colors.ink2)
                        }
                        Spacer()
                        signal(probe.rssiLast)
                    }
                }
            }
        } header: {
            Text("Clients that looked for it")
        } footer: {
            if detail.clients.count < detail.network.clientCount {
                Text("Showing the \(DataFormat.count(detail.clients.count)) strongest of \(DataFormat.count(detail.network.clientCount)).")
            }
        }
    }

    private func signal(_ rssi: Int) -> some View {
        Text(DataFormat.dBm(rssi))
            .font(Theme.Fonts.counter)
            .foregroundStyle(Theme.Colors.signal(Int32(clamping: rssi)))
    }
}
