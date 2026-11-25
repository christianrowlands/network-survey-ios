import SurveyCore
import SwiftUI

/// "Watched" next to an access point on the watchlist (alerts on or off);
/// nothing otherwise. Drop it into a row's tags.
struct WatchedTag: View {
    let ssid: String?
    let bssid: String
    /// A whole SSID group: watched when an entry names the network.
    var group = false

    @Environment(AppModel.self) private var app

    var body: some View {
        let watched = if group, let ssid {
            app.watchlist.watchesNetwork(ssid: ssid)
        } else {
            app.watchlist.isWatched(ssid: ssid, bssid: bssid)
        }
        if watched {
            TagPill(text: "Watched", color: Theme.Colors.accent)
                .accessibilityLabel("On watchlist")
                .accessibilityIdentifier("watchlist.watched")
        }
    }
}

/// Shows the add form for `WatchlistModel.draft`. Attach it to a view that
/// stays put (the detail's list), not to a row: the detail reloads its rows
/// every second, which would close a sheet attached to one.
struct WatchlistAddSheet: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        @Bindable var watchlist = app.watchlist
        content.sheet(item: $watchlist.draft) { draft in
            NavigationStack {
                WatchlistEntryEditor(mode: .add(ssid: draft.ssid, bssid: draft.bssid, turnOnAlerts: true))
            }
            .presentationDetents([.medium, .large])
        }
    }
}

extension View {
    func watchlistAddSheet() -> some View {
        modifier(WatchlistAddSheet())
    }
}

/// The watchlist part of an access point's or a probed network's details:
/// on the watchlist (open it), or add it, prefilled. With no BSSID it watches
/// the network name on any access point.
struct WatchlistDetailSection: View {
    let ssid: String?
    let bssid: String?

    @Environment(AppModel.self) private var app
    @Environment(SettingsModel.self) private var settings

    var body: some View {
        let entry = if let bssid { app.watchlist.entry(ssid: ssid, bssid: bssid) } else { ssid.flatMap(app.watchlist.entry(network:)) }
        Section {
            if let entry {
                NavigationLink {
                    WatchlistEntryScreen(uuid: entry.uuid)
                } label: {
                    InfoRow(symbol: "eye.fill", symbolColor: Theme.Colors.accent, title: "On watchlist",
                            detail: [entry.enabled ? entry.label : "\(entry.label), alerts off"]) {}
                }
                .accessibilityIdentifier("watchlist.onWatchlist")
            } else {
                Button {
                    app.watchlist.draft = WatchlistModel.Draft(ssid: ssid ?? "", bssid: bssid?.lowercased() ?? "")
                } label: {
                    Label("Add to watchlist", systemImage: "eye")
                }
                .accessibilityIdentifier("watchlist.addFromDetail")
            }
        } header: {
            Text("Watchlist")
        } footer: {
            if entry == nil {
                Text(bssid == nil
                    ? "Get a notification when a Scout sees an access point with this name during a survey. Adding it turns watchlist alerts on."
                    : "Get a notification when a Scout sees this network during a survey. Adding it turns watchlist alerts on.")
            } else if settings[Settings.watchlistEnabled] {
                Text("You get a notification when a Scout sees it during a survey.")
            } else {
                Text("Watchlist alerts are off. Turn them on in Tools > Watchlist.")
            }
        }
    }
}
