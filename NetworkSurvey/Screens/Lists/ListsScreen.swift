import BoardProtocol
import SurveyCore
import SwiftUI

/// Everything seen in a survey, as three searchable, sortable lists.
struct ListsScreen: View {
    enum Segment: String, CaseIterable, Identifiable {
        case aps = "Wi-Fi APs"
        case clients = "Wi-Fi Clients"
        case ble = "BLE"
        var id: Self { self }

        var searchPrompt: String {
            switch self {
            case .aps: "Network name or BSSID"
            case .clients: "MAC address or network"
            case .ble: "Name or address"
            }
        }
    }

    @Environment(SurveyData.self) private var data
    @State private var segment = Segment.aps
    @State private var filters = ListFilters()
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let sessionID = data.sessionID {
                    EntityList(segment: segment, sessionID: sessionID, filters: filters, isPaused: !path.isEmpty)
                } else {
                    NoSurveyView(message: "Start a survey to see access points, clients and Bluetooth devices here.")
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("List", selection: $segment) {
                    ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("lists.segment")
                .padding(.horizontal, Theme.Spacing.screenGutter)
                .padding(.vertical, Theme.Spacing.s)
                .background(Theme.Colors.ground)
            }
            .searchable(text: $filters.search, placement: .navigationBarDrawer(displayMode: .always), prompt: segment.searchPrompt)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    SortMenu(sort: $filters.sort)
                    FilterMenu(filters: $filters, segment: segment)
                }
                ToolbarItem(placement: .principal) {
                    SessionTitle(title: "Lists")
                }
            }
            .screenBackground()
            .navigationTitle("Lists")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: DetailRoute.self) { route in
                DetailScreen(route: route)
            }
        }
    }
}

/// The search, sort and filter state shared by the three lists.
struct ListFilters: Equatable {
    var search = ""
    var sort = ListSort.rssi
    var bands: Set<NSBBand> = []
    var securities: Set<NSBSecurityType> = []
    var hideRandomized = false

    /// Rows shown at most; a search narrows the rest.
    static let rowLimit = 1000

    /// Security filters apply to APs only, band filters to Wi-Fi only, and
    /// "hide randomized" to clients and BLE (a locally administered BSSID is
    /// usually a virtual AP, not a privacy address).
    func query(for segment: ListsScreen.Segment) -> ListQuery {
        ListQuery(
            search: search.trimmingCharacters(in: .whitespaces), sort: sort, bands: segment == .ble ? [] : bands,
            securities: segment == .aps ? securities : [], hideRandomized: segment != .aps && hideRandomized,
            limit: Self.rowLimit
        )
    }

    func isFiltering(_ segment: ListsScreen.Segment) -> Bool {
        let query = query(for: segment)
        return !query.bands.isEmpty || !query.securities.isEmpty || query.hideRandomized
    }
}

private struct SortMenu: View {
    @Binding var sort: ListSort

    var body: some View {
        Menu {
            Picker("Sort by", selection: $sort) {
                Text("Signal").tag(ListSort.rssi)
                Text("Last seen").tag(ListSort.lastSeen)
                Text("Frame count").tag(ListSort.count)
                Text("Name").tag(ListSort.name)
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityIdentifier("lists.sort")
    }
}

private struct FilterMenu: View {
    @Binding var filters: ListFilters
    let segment: ListsScreen.Segment

    private static let securityChoices: [NSBSecurityType] = [.open, .wep, .wpa, .wpaWpa2, .wpa2, .wpa2Wpa3, .wpa3, .owe]

    var body: some View {
        Menu {
            if segment != .aps {
                Toggle("Hide randomized addresses", isOn: $filters.hideRandomized)
            }
            if segment != .ble {
                Section("Band") {
                    ForEach(DataFormat.filterBands, id: \.self) { band in
                        Toggle(DataFormat.band(band.rawValue), isOn: member(band, of: \.bands))
                    }
                }
            }
            if segment == .aps {
                Section("Security") {
                    ForEach(Self.securityChoices, id: \.self) { security in
                        Toggle(DataFormat.security(security.rawValue), isOn: member(security, of: \.securities))
                    }
                }
            }
            if filters.isFiltering(segment) {
                Button("Clear filters", role: .destructive) {
                    filters.bands = []
                    filters.securities = []
                    filters.hideRandomized = false
                }
            }
        } label: {
            Label("Filter", systemImage: filters.isFiltering(segment)
                ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .menuActionDismissBehavior(.disabled)
        .accessibilityIdentifier("lists.filter")
        .accessibilityValue(filters.isFiltering(segment) ? "Filters on" : "No filters")
    }

    private func member<T: Hashable>(_ value: T, of keyPath: WritableKeyPath<ListFilters, Set<T>>) -> Binding<Bool> {
        Binding(
            get: { filters[keyPath: keyPath].contains(value) },
            set: { isOn in
                if isOn { filters[keyPath: keyPath].insert(value) } else { filters[keyPath: keyPath].remove(value) }
            }
        )
    }
}
