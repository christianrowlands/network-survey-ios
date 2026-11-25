import SurveyCore
import SwiftUI

/// The watched networks: the alerts switch, one row per network with how
/// often it was seen, and adding, history and clearing. Opened from Tools and
/// from an access point's details.
struct WatchlistScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(SettingsModel.self) private var settings
    @Environment(\.openURL) private var openURL
    @State private var adding = false
    @State private var confirmingClear = false
    @State private var pasting = false
    @State private var openedLink: OpenedLink?

    var body: some View {
        let watchlist = app.watchlist
        List {
            Group {
                Section {
                    Toggle(isOn: settings.binding(Settings.watchlistEnabled)) {
                        Label("Watchlist alerts", systemImage: "bell")
                    }
                    .accessibilityIdentifier("watchlist.alerts")
                    if watchlist.notificationsDenied {
                        InfoRow(symbol: "bell.slash", symbolColor: Theme.Colors.amber, title: "Notifications are off",
                                detail: ["Sightings are still saved in History."]) {
                            Button("Turn on") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } footer: {
                    Text(settings[Settings.watchlistEnabled]
                        ? "During a survey, every access point a Scout hears is checked against this list. When a watched network appears, you get a notification and the sighting is saved in History."
                        : "Alerts are off. Turn them on to be notified when a Scout sees a watched network during a survey.")
                }
                if watchlist.summaries.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                            Text("No watched networks")
                                .font(Theme.Fonts.sectionTitle)
                                .foregroundStyle(Theme.Colors.ink)
                            Text("Add a network to get a notification when a Scout sees it. You can also add one from an access point's details.")
                                .font(Theme.Fonts.body)
                                .foregroundStyle(Theme.Colors.ink2)
                            Button("Add network") { adding = true }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("watchlist.addEmpty")
                        }
                        .padding(.vertical, Theme.Spacing.xs)
                    }
                } else {
                    Section("Watched networks") {
                        ForEach(watchlist.summaries) { summary in
                            NavigationLink {
                                WatchlistEntryScreen(uuid: summary.entry.uuid)
                            } label: {
                                WatchlistEntryRow(summary: summary)
                            }
                            .swipeActions {
                                Button("Remove", role: .destructive) { watchlist.delete(summary.entry) }
                            }
                        }
                    }
                }
                Section {
                    Toggle(isOn: settings.binding(Settings.watchlistStreamMQTT)) {
                        Label("Stream over MQTT", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .accessibilityIdentifier("watchlist.streamMQTT")
                } footer: {
                    Text("While a survey streams to an MQTT broker, sightings and your watched networks, with their names, are sent to it.")
                }
            }
            .panelRows()
        }
        .themedList()
        .navigationTitle("Watchlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink {
                    WatchlistHistoryScreen()
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("watchlist.history")
                Menu {
                    if let link = try? WatchlistLink.makeURL(entries: watchlist.entries) {
                        ShareLink(item: link, subject: Text("Watchlist"),
                                  message: Text("Networks to watch with Network Survey")) {
                            Label("Share watchlist", systemImage: "square.and.arrow.up")
                        }
                    } else if watchlist.entries.count > WatchlistLimits.maxEntries {
                        Text("A share link holds at most \(WatchlistLimits.maxEntries) networks")
                    }
                    Button("Import from a link", systemImage: "link") { pasting = true }
                        .accessibilityIdentifier("watchlist.import")
                    Button("Clear all", systemImage: "trash", role: .destructive) { confirmingClear = true }
                        .disabled(watchlist.summaries.isEmpty)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("watchlist.more")
                Button {
                    adding = true
                } label: {
                    Label("Add network", systemImage: "plus")
                }
                .accessibilityIdentifier("watchlist.add")
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack { WatchlistEntryEditor(mode: .add(ssid: "", bssid: "", turnOnAlerts: false)) }
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $pasting) { WatchlistPasteImport() }
        .sheet(item: $openedLink) { WatchlistLinkImport(url: $0.url) }
        .onChange(of: app.pendingWatchlistLink, initial: true) { _, link in
            // A link opened from outside the app.
            guard let link else { return }
            openedLink = OpenedLink(url: link)
            app.pendingWatchlistLink = nil
        }
        .confirmationDialog("Clear the watchlist?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear all", role: .destructive) { watchlist.clearAll() }
        } message: {
            Text("This removes every watched network and its history. It can't be undone.")
        }
        .task { await watchlist.refreshNotificationStatus() }
    }
}

/// One watched network: its name, what it matches, and when it was last seen.
struct WatchlistEntryRow: View {
    let summary: WatchlistEntrySummary

    var body: some View {
        let entry = summary.entry
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(entry.label)
                    .font(Theme.Fonts.rowTitle.weight(.medium))
                    .foregroundStyle(entry.enabled ? Theme.Colors.ink : Theme.Colors.ink2)
                    .lineLimit(1)
                WatchlistIdentity(entry: entry)
                HStack(spacing: Theme.Spacing.xs) {
                    if !entry.enabled { TagPill(text: "Alerts off", color: Theme.Colors.tagHidden) }
                    Text(seenText)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.ink2)
                }
            }
            Spacer(minLength: Theme.Spacing.s)
            if let rssi = summary.lastRssi {
                Text(DataFormat.dBm(rssi))
                    .font(Theme.Fonts.counter.weight(.semibold))
                    .foregroundStyle(Theme.Colors.signal(Int32(clamping: rssi)))
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .accessibilityElement(children: .combine)
    }

    private var seenText: String {
        guard let lastSeen = summary.lastSeen else { return "Not seen yet" }
        let times = summary.sightings == 1 ? "once" : "\(DataFormat.count(summary.sightings)) times"
        return "Seen \(times), last \(DataFormat.ago(lastSeen))"
    }
}

/// What an entry matches: the network name, the access point, or both.
struct WatchlistIdentity: View {
    let entry: WatchlistEntry

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            if let ssid = entry.ssid {
                Text("Network \u{201C}\(ssid)\u{201D}")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.ink2)
                    .lineLimit(1)
            }
            if let bssid = entry.bssid {
                Text(bssid)
                    .font(Theme.Fonts.mono)
                    .foregroundStyle(Theme.Colors.ink2)
            }
        }
    }
}

/// A link to import, for `.sheet(item:)`.
struct OpenedLink: Identifiable {
    let id = UUID()
    let url: URL
}
