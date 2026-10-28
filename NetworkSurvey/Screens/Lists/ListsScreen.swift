import BoardProtocol
import SurveyCore
import SwiftUI

/// Everything seen in a survey, as searchable, sortable lists.
struct ListsScreen: View {
    enum Segment: String, CaseIterable, Identifiable {
        case aps = "APs"
        case clients = "Clients"
        case probes = "Probes"
        case ble = "Bluetooth"
        var id: Self { self }
    }

    /// Probe requests by the network looked for, or by the client looking.
    enum ProbeGrouping: String, CaseIterable, Identifiable {
        case network = "By network"
        case client = "By client"
        var id: Self { self }
    }

    @Environment(SurveyData.self) private var data
    @Environment(ListsNavigation.self) private var navigation
    @State private var filters = ListFilters()

    var body: some View {
        @Bindable var navigation = navigation
        let kind = navigation.kind
        NavigationStack(path: $navigation.path) {
            Group {
                if let sessionID = data.sessionID {
                    EntityList(kind: kind, sessionID: sessionID, filters: filters, isPaused: !navigation.path.isEmpty)
                } else {
                    if navigation.segment == .ble {
                        NoSurveyView(message: "Start a survey to see the Bluetooth devices your NS Scouts hear.", offersNearby: true)
                    } else {
                        NoSurveyView(message: "Start a survey to see access points, clients, probe requests and Bluetooth devices here.")
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    PastSurveyBar()
                    VStack(spacing: Theme.Spacing.s) {
                        Picker("List", selection: $navigation.segment) {
                            ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .accessibilityIdentifier("lists.segment")
                        if navigation.segment == .probes {
                            Picker("Group probe requests", selection: $navigation.probeGrouping) {
                                ForEach(ProbeGrouping.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .accessibilityIdentifier("lists.probeGrouping")
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, Theme.Spacing.screenGutter)
                    .padding(.vertical, Theme.Spacing.s)
                }
                .background(Theme.Colors.ground)
            }
            .searchable(text: $filters.search, placement: .navigationBarDrawer(displayMode: .always), prompt: kind.searchPrompt)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    SortMenu(sort: $filters.sort, kind: kind)
                    FilterMenu(filters: $filters, kind: kind)
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

/// The list shown: a segment, with probe requests grouped one of two ways.
enum ListKind: Hashable {
    case aps, clients, probeNetworks, probeClients, ble

    var searchPrompt: String {
        switch self {
        case .aps: "Network name or BSSID"
        case .clients, .probeClients: "MAC address or network"
        case .probeNetworks: "Network name"
        case .ble: "Name or address"
        }
    }
}

/// Which list the Lists tab shows and its navigation, so other tabs can
/// open a list.
@Observable
final class ListsNavigation {
    var segment = ListsScreen.Segment.aps
    var probeGrouping = ListsScreen.ProbeGrouping.network
    var path = NavigationPath()

    var kind: ListKind {
        switch segment {
        case .aps: .aps
        case .clients: .clients
        case .probes: probeGrouping == .network ? .probeNetworks : .probeClients
        case .ble: .ble
        }
    }

    /// Shows a list from the top, closing any open detail screen.
    func show(_ segment: ListsScreen.Segment) {
        self.segment = segment
        path = NavigationPath()
    }
}

/// The search, sort and filter state shared by the lists.
struct ListFilters: Equatable {
    var search = ""
    var sort = ListSort.rssi
    var bands: Set<NSBBand> = []
    var securities: Set<NSBSecurityType> = []
    var hideRandomized = false

    /// Rows shown at most; a search narrows the rest.
    static let rowLimit = 1000

    /// Security filters apply to APs only, band filters to Wi-Fi only, and
    /// "hide randomized" to clients, probes and BLE (a locally administered
    /// BSSID is usually a virtual AP, not a privacy address).
    func query(for kind: ListKind) -> ListQuery {
        ListQuery(
            search: search.trimmingCharacters(in: .whitespaces), sort: sort, bands: kind == .ble ? [] : bands,
            securities: kind == .aps ? securities : [], hideRandomized: kind != .aps && hideRandomized,
            limit: Self.rowLimit
        )
    }

    func isFiltering(_ kind: ListKind) -> Bool {
        let query = query(for: kind)
        return !query.bands.isEmpty || !query.securities.isEmpty || query.hideRandomized
    }
}

private struct SortMenu: View {
    @Binding var sort: ListSort
    let kind: ListKind

    var body: some View {
        Menu {
            Picker("Sort by", selection: $sort) {
                Text("Signal").tag(ListSort.rssi)
                Text("Last seen").tag(ListSort.lastSeen)
                Text(countTitle).tag(ListSort.count)
                Text(kind == .probeClients || kind == .clients ? "MAC address" : "Name").tag(ListSort.name)
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityIdentifier("lists.sort")
    }

    private var countTitle: String {
        switch kind {
        case .probeNetworks: "Client count"
        case .probeClients: "Network count"
        default: "Frame count"
        }
    }
}

private struct FilterMenu: View {
    @Binding var filters: ListFilters
    let kind: ListKind

    private static let securityChoices: [NSBSecurityType] = [.open, .wep, .wpa, .wpaWpa2, .wpa2, .wpa2Wpa3, .wpa3, .owe]

    var body: some View {
        Menu {
            if kind != .aps {
                Toggle("Hide randomized addresses", isOn: $filters.hideRandomized)
            }
            if kind != .ble {
                Section("Band") {
                    ForEach(DataFormat.filterBands, id: \.self) { band in
                        Toggle(DataFormat.band(band.rawValue), isOn: member(band, of: \.bands))
                    }
                }
            }
            if kind == .aps {
                Section("Security") {
                    ForEach(Self.securityChoices, id: \.self) { security in
                        Toggle(DataFormat.security(security.rawValue), isOn: member(security, of: \.securities))
                    }
                }
            }
            if filters.isFiltering(kind) {
                Button("Clear filters", role: .destructive) {
                    filters.bands = []
                    filters.securities = []
                    filters.hideRandomized = false
                }
            }
        } label: {
            Label("Filter", systemImage: filters.isFiltering(kind)
                ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .menuActionDismissBehavior(.disabled)
        .accessibilityIdentifier("lists.filter")
        .accessibilityValue(filters.isFiltering(kind) ? "Filters on" : "No filters")
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
