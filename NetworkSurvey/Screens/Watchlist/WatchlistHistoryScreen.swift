import SurveyCore
import SwiftUI

/// Every watched network that was seen, with how often, when and the best
/// signal. A network opens its sightings.
struct WatchlistHistoryScreen: View {
    enum Sort: String, CaseIterable {
        case recent = "Most recent"
        case strongest = "Strongest"
        case mostSeen = "Most seen"
    }

    @Environment(AppModel.self) private var app
    @State private var groups: [WatchlistHistoryGroup] = []
    @State private var loaded = false
    @State private var search = ""
    @State private var sort = Sort.recent
    @State private var confirmingClear = false

    var body: some View {
        let shown = Self.arrange(groups, search: search, sort: sort)
        List {
            Group {
                if !groups.isEmpty {
                    Section {
                        ForEach(shown) { group in
                            NavigationLink {
                                WatchlistEntryScreen(uuid: group.entry.uuid)
                            } label: {
                                WatchlistHistoryRow(group: group)
                            }
                        }
                    } header: {
                        Text("\(DataFormat.count(shown.reduce(0) { $0 + $1.sightings }, "sighting")) of \(DataFormat.count(shown.count, "network"))")
                    }
                }
            }
            .panelRows()
        }
        .themedList()
        .overlay {
            if loaded && groups.isEmpty {
                ContentUnavailableView("Nothing seen yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("When a Scout sees a watched network during a survey, the sighting shows up here."))
            } else if !groups.isEmpty && shown.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .searchable(text: $search, prompt: "Search networks")
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                Button {
                    confirmingClear = true
                } label: {
                    Label("Clear history", systemImage: "trash")
                }
                .disabled(groups.isEmpty)
            }
        }
        .confirmationDialog("Clear the history?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { app.watchlist.clearHistory() }
        } message: {
            Text("This removes every sighting. Your watched networks stay.")
        }
        .task {
            do {
                for try await value in app.store.observe(WatchlistQueries.historyGroups) {
                    groups = value
                    loaded = true
                }
            } catch {}
        }
    }

    nonisolated static func arrange(_ groups: [WatchlistHistoryGroup], search: String, sort: Sort) -> [WatchlistHistoryGroup] {
        let text = search.trimmingCharacters(in: .whitespaces)
        let filtered = text.isEmpty ? groups : groups.filter { group in
            [group.entry.label, group.entry.ssid ?? "", group.entry.bssid ?? ""].contains { $0.localizedCaseInsensitiveContains(text) }
        }
        switch sort {
        case .recent: return filtered.sorted { $0.lastSeen > $1.lastSeen }
        case .strongest: return filtered.sorted { ($0.bestRssi ?? Int.min, $0.lastSeen) > ($1.bestRssi ?? Int.min, $1.lastSeen) }
        case .mostSeen: return filtered.sorted { ($0.sightings, $0.lastSeen) > ($1.sightings, $1.lastSeen) }
        }
    }
}

struct WatchlistHistoryRow: View {
    let group: WatchlistHistoryGroup

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(group.entry.label)
                    .font(Theme.Fonts.rowTitle.weight(.medium))
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                Text("\(DataFormat.count(group.sightings, "sighting")), matched by \(group.entry.matchedField == .ssid ? "name" : "access point")")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.ink2)
            }
            Spacer(minLength: Theme.Spacing.s)
            VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
                if let rssi = group.bestRssi {
                    Text(DataFormat.dBm(rssi))
                        .font(Theme.Fonts.counter.weight(.semibold))
                        .foregroundStyle(Theme.Colors.signal(Int32(clamping: rssi)))
                }
                Text(DataFormat.ago(group.lastSeen))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.ink2)
            }
            .fixedSize()
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .accessibilityElement(children: .combine)
    }
}
