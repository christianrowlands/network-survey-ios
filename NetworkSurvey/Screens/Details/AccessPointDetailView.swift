import SurveyCore
import SwiftUI

struct AccessPointDetailView: View {
    let sessionID: String
    let bssid: String

    var body: some View {
        LiveDetail(query: { [sessionID, bssid] store in
            store.observe { try StoreQueries.accessPointDetail($0, sessionID: sessionID, bssid: bssid) }
        }) { detail in
            AccessPointDetailContent(sessionID: sessionID, detail: detail)
        }
        .navigationTitle("Access point")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AccessPointDetailContent: View {
    let sessionID: String
    let detail: AccessPointDetail

    var body: some View {
        let ap = detail.accessPoint
        List {
            Group {
                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Text(DataFormat.ssid(ap.ssid, hidden: ap.ssidHidden))
                            .font(Theme.Fonts.screenTitle)
                            .foregroundStyle(Theme.Colors.ink)
                            .accessibilityAddTraits(.isHeader)
                        TagRow {
                            TagPill(text: DataFormat.security(ap.security), color: DataFormat.securityColor(ap.security))
                            BandTag(band: ap.band, channel: ap.channel)
                            if ap.ssidHidden { TagPill(text: "Hidden", color: Theme.Colors.tagHidden) }
                        }
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                }
                Section("Signal") {
                    RSSIChart(points: detail.rssiHistory)
                        .padding(.vertical, Theme.Spacing.xs)
                }
                Section("Identity") {
                    DetailRow(label: "BSSID", value: ap.bssid, mono: true)
                    if ap.randomized {
                        DetailRow(label: "BSSID type", value: "Locally administered (likely a virtual AP)")
                    }
                    DetailRow(label: "Network name", value: ap.ssid?.isEmpty == false ? ap.ssid! : "Not broadcast")
                    if let standards = DataFormat.standards(phyFlags: ap.phyFlags) {
                        DetailRow(label: "Wi-Fi", value: standards)
                    }
                    if ap.wps { DetailRow(label: "WPS", value: "On") }
                    if ap.passpoint { DetailRow(label: "Passpoint", value: "Yes") }
                    if let interval = ap.beaconIntervalTu { DetailRow(label: "Beacon interval", value: "\(interval) TU") }
                    if let stations = ap.stationCount { DetailRow(label: "Stations (BSS load)", value: "\(stations)") }
                    if let utilization = ap.channelUtilization {
                        DetailRow(label: "Channel use", value: "\(Int((Double(utilization) / 255 * 100).rounded())) %")
                    }
                }
                Section("Security") {
                    DetailRow(label: "Type", value: DataFormat.security(ap.security))
                    if !ap.akmSuites.isEmpty { DetailRow(label: "Key management", value: DataFormat.akmSuites(ap.akmSuites)) }
                    if !ap.pairwiseCiphers.isEmpty { DetailRow(label: "Pairwise ciphers", value: DataFormat.cipherSuites(ap.pairwiseCiphers)) }
                    if ap.groupCipher != 0 { DetailRow(label: "Group cipher", value: DataFormat.cipherSuites(String(ap.groupCipher))) }
                }
                Section {
                    DetailRow(label: "Band", value: DataFormat.band(ap.band))
                    DetailRow(label: "Channel", value: "\(ap.channel) (\(ap.frequencyMhz) MHz)")
                    if let width = DataFormat.channelWidth(ap.channelWidth) { DetailRow(label: "Width", value: width) }
                    DetailRow(label: "Heard on", value: detail.channels.isEmpty
                        ? "None" : detail.channels.map(String.init).joined(separator: ", "))
                } header: {
                    Text("Channel")
                } footer: {
                    Text("Heard on lists every channel where a Scout received this access point, including adjacent 2.4 GHz channels.")
                }
                ObservationSection(entity: ap)
                Section("Connected clients") {
                    if detail.associatedClients.isEmpty {
                        Text("No clients seen connected to this access point.")
                            .foregroundStyle(Theme.Colors.ink2)
                    } else {
                        ForEach(detail.associatedClients, id: \.mac) { client in
                            NavigationLink(value: DetailRoute.client(sessionID: sessionID, mac: client.mac)) {
                                HStack {
                                    Text(client.mac).font(Theme.Fonts.mono)
                                    if client.randomized { RandomizedBadge() }
                                    Spacer()
                                    Text(DataFormat.dBm(client.rssiLast))
                                        .font(Theme.Fonts.counter)
                                        .foregroundStyle(Theme.Colors.signal(Int32(clamping: client.rssiLast)))
                                }
                            }
                        }
                    }
                }
            }
            .panelRows()
        }
        .themedList()
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                IgnoreMenu(choices: ignoreChoices)
            }
        }
    }

    private var ignoreChoices: [IgnoreChoice] {
        let ap = detail.accessPoint
        var choices = [IgnoreChoice(kind: .bssid, value: ap.bssid, title: "Ignore this access point (BSSID)")]
        if let ssid = ap.ssid, !ssid.isEmpty {
            choices.append(IgnoreChoice(kind: .ssid, value: ssid, title: "Ignore every \(ssid) network (SSID)"))
        }
        return choices
    }
}
