import MapKit
import SurveyCore
import SwiftUI

/// One watched network: what it matches, its alerts switch, and every
/// sighting with when and where it was seen.
struct WatchlistEntryScreen: View {
    let uuid: String

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var hits: [WatchlistHit] = []
    @State private var editing = false
    @State private var confirmingRemove = false
    @State private var confirmingClear = false

    var body: some View {
        let watchlist = app.watchlist
        Group {
            if let summary = watchlist.summaries.first(where: { $0.entry.uuid == uuid }) {
                content(summary.entry)
                    .task(id: summary.entry.id) { await follow(summary.entry) }
            } else {
                ContentUnavailableView("Not on the watchlist", systemImage: "eye.slash",
                                       description: Text("This network was removed from the watchlist."))
            }
        }
        .navigationTitle("Watched network")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ entry: WatchlistEntry) -> some View {
        List {
            Group {
                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Text(entry.label)
                            .font(Theme.Fonts.screenTitle)
                            .foregroundStyle(Theme.Colors.ink)
                            .accessibilityAddTraits(.isHeader)
                        WatchlistIdentity(entry: entry)
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                    Toggle("Alerts for this network", isOn: Binding(
                        get: { entry.enabled }, set: { app.watchlist.setEnabled(entry, $0) }
                    ))
                    .accessibilityIdentifier("watchlist.entryEnabled")
                } footer: {
                    Text(Self.matchText(entry))
                }
                let located = hits.filter(\.hasLocation)
                if !located.isEmpty {
                    Section {
                        WatchlistSightingsMap(hits: located)
                            .frame(height: 200)
                            .listRowInsets(EdgeInsets())
                    }
                }
                Section {
                    if hits.isEmpty {
                        Text("Not seen yet. Sightings during a survey show up here.")
                            .foregroundStyle(Theme.Colors.ink2)
                    } else {
                        ForEach(hits, id: \.id) { WatchlistHitRow(hit: $0) }
                    }
                } header: {
                    Text(hits.isEmpty ? "Sightings" : "Sightings (\(DataFormat.count(hits.count)))")
                }
                Section {
                    if !hits.isEmpty {
                        Button("Clear sightings", role: .destructive) { confirmingClear = true }
                    }
                    Button("Remove from watchlist", role: .destructive) { confirmingRemove = true }
                        .accessibilityIdentifier("watchlist.remove")
                }
            }
            .panelRows()
        }
        .themedList()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { editing = true }
                    .accessibilityIdentifier("watchlist.edit")
            }
        }
        .sheet(isPresented: $editing) {
            NavigationStack { WatchlistEntryEditor(mode: .edit(entry)) }
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog("Remove from the watchlist?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                app.watchlist.delete(entry)
                dismiss()
            }
        } message: {
            Text("Stop watching \(entry.label). Its sightings are removed too.")
        }
        .confirmationDialog("Clear the sightings?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear sightings", role: .destructive) { app.watchlist.clearHistory(entryID: entry.id) }
        } message: {
            Text("This removes the sightings of \(entry.label). The network stays on the watchlist.")
        }
    }

    private func follow(_ entry: WatchlistEntry) async {
        guard let id = entry.id else { return }
        do {
            for try await value in app.store.observe({ try WatchlistQueries.hits($0, entryID: id) }) { hits = value }
        } catch {}
    }

    static func matchText(_ entry: WatchlistEntry) -> String {
        switch (entry.ssid, entry.bssid) {
        case (.some, .some): "Matches only when this access point broadcasts this network name."
        case (.some, nil): "Matches this network name on any access point, whatever the case."
        default: "Matches this access point, whatever name it broadcasts."
        }
    }
}

/// One sighting: when, the signal, the access point and where.
struct WatchlistHitRow: View {
    let hit: WatchlistHit

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline) {
                Text(DataFormat.dateTime(hit.timestamp))
                    .font(Theme.Fonts.rowTitle)
                    .foregroundStyle(Theme.Colors.ink)
                Spacer(minLength: Theme.Spacing.s)
                if let rssi = hit.rssi {
                    Text(DataFormat.dBm(rssi))
                        .font(Theme.Fonts.counter.weight(.semibold))
                        .foregroundStyle(Theme.Colors.signal(Int32(clamping: rssi)))
                }
            }
            Text("\(hit.ssid.isEmpty ? "Hidden network" : hit.ssid) on \(hit.bssid)")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Colors.ink2)
            Text(location)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.ink2)
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .accessibilityElement(children: .combine)
    }

    private var location: String {
        guard let latitude = hit.latitude, let longitude = hit.longitude else { return "No location" }
        return String(format: "%.5f, %.5f", latitude, longitude)
    }
}

/// The located sightings of one network as pins.
struct WatchlistSightingsMap: View {
    let hits: [WatchlistHit]

    var body: some View {
        Map(initialPosition: .automatic, interactionModes: [.pan, .zoom]) {
            ForEach(hits, id: \.id) { hit in
                if let latitude = hit.latitude, let longitude = hit.longitude {
                    Marker(DataFormat.dateTime(hit.timestamp), systemImage: "eye",
                           coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
                        .tint(Theme.Colors.accent)
                }
            }
        }
        .accessibilityLabel("Map of \(DataFormat.count(hits.count, "sighting"))")
    }
}
