import SurveyCore
import SwiftUI

struct ClientDetailView: View {
    let sessionID: String
    let mac: String

    var body: some View {
        LiveDetail(query: { [sessionID, mac] store in
            store.observe { try StoreQueries.clientDetail($0, sessionID: sessionID, mac: mac) }
        }) { detail in
            ClientDetailContent(sessionID: sessionID, detail: detail)
        }
        .navigationTitle("Client")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                IgnoreMenu(choices: [IgnoreChoice(kind: .mac, value: mac, title: "Ignore this device (MAC)")])
            }
        }
    }
}

private struct ClientDetailContent: View {
    let sessionID: String
    let detail: ClientDetail

    var body: some View {
        let client = detail.client
        List {
            Group {
                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Text(client.mac)
                            .font(Theme.Fonts.mono)
                            .foregroundStyle(Theme.Colors.ink)
                            .textSelection(.enabled)
                            .accessibilityAddTraits(.isHeader)
                        TagRow {
                            if client.band > 0 { BandTag(band: client.band, channel: client.channel) }
                            if client.randomized { RandomizedBadge() }
                        }
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                } footer: {
                    if client.randomized {
                        Text("This address has the locally administered bit set, so it is most likely a randomized (private) address that changes over time.")
                    }
                }
                Section("Signal") {
                    RSSIChart(points: detail.rssiHistory)
                        .padding(.vertical, Theme.Spacing.xs)
                }
                Section("Connected to") {
                    if detail.associatedAPs.isEmpty {
                        Text("Not seen connected to an access point.")
                            .foregroundStyle(Theme.Colors.ink2)
                    } else {
                        ForEach(detail.associatedAPs, id: \.bssid) { ap in
                            NavigationLink(value: DetailRoute.accessPoint(sessionID: sessionID, bssid: ap.bssid)) {
                                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                    Text(ap.ssid?.isEmpty == false ? ap.ssid! : "Unknown network")
                                        .foregroundStyle(Theme.Colors.ink)
                                    Text(ap.bssid).font(Theme.Fonts.mono).foregroundStyle(Theme.Colors.ink2)
                                }
                            }
                        }
                    }
                }
                Section {
                    if detail.probes.isEmpty {
                        Text("No probe requests seen from this client.")
                            .foregroundStyle(Theme.Colors.ink2)
                    } else {
                        ForEach(detail.probes, id: \.ssid) { probe in
                            HStack {
                                Text(probe.isWildcard ? "Any network (wildcard)" : probe.ssid)
                                    .foregroundStyle(probe.isWildcard ? Theme.Colors.ink2 : Theme.Colors.ink)
                                Spacer()
                                Text(DataFormat.count(probe.frameCount))
                                    .font(Theme.Fonts.counter)
                                    .foregroundStyle(Theme.Colors.ink2)
                                    .accessibilityLabel("\(probe.frameCount) requests")
                            }
                        }
                    }
                } header: {
                    Text("Networks it looked for")
                } footer: {
                    Text("Network names from probe requests: the client's saved networks (preferred network list).")
                }
                Section("Details") {
                    if let sources = DataFormat.clientSources(client.sourceFlags) {
                        DetailRow(label: "Seen in", value: sources)
                    }
                }
                ObservationSection(entity: client)
            }
            .panelRows()
        }
        .themedList()
        .listStyle(.insetGrouped)
    }
}
