import SurveyCore
import SwiftUI

/// One list, kept live with a GRDB observation while a survey writes.
///
/// Rows must not jump under the user's finger, so new data updates rows in
/// place and appends new ones; the full sort order is applied at most every
/// `reorderInterval`, and nothing changes while the list scrolls or a detail
/// screen is open (`isPaused`).
struct EntityList: View {
    let kind: ListKind
    let sessionID: String
    let filters: ListFilters
    let isPaused: Bool

    static let reorderInterval: TimeInterval = 10

    @Environment(SurveyData.self) private var data
    @Environment(AppModel.self) private var model
    @State private var rows = Rows.none
    @State private var pending: Rows?
    @State private var loaded = false
    @State private var failure: String?
    @State private var scrolling = false
    @State private var lastReorder = Date.distantPast
    @State private var shown: Shown?

    /// The list identity; a change replaces the rows instead of merging.
    private struct Shown: Equatable {
        var kind: ListKind
        var sessionID: String
        var filters: ListFilters
    }

    enum Rows: Equatable {
        case none
        case aps([AccessPointRow])
        case clients([ClientListItem])
        case probeNetworks([ProbeNetworkRow])
        case probeClients([ProbeClientRow])
        case ble([BLEDeviceRow])

        var count: Int {
            switch self {
            case .none: 0
            case .aps(let rows): rows.count
            case .clients(let rows): rows.count
            case .probeNetworks(let rows): rows.count
            case .probeClients(let rows): rows.count
            case .ble(let rows): rows.count
            }
        }

        /// `new` with the current order kept: known rows stay where they are
        /// with fresh values, gone rows leave, new rows go to the end.
        func merged(with new: Rows) -> Rows {
            switch (self, new) {
            case (.aps(let old), .aps(let fresh)): .aps(StableOrder.merge(old, fresh, id: \.bssid))
            case (.clients(let old), .clients(let fresh)): .clients(StableOrder.merge(old, fresh, id: \.client.mac))
            case (.probeNetworks(let old), .probeNetworks(let fresh)): .probeNetworks(StableOrder.merge(old, fresh, id: \.ssid))
            case (.probeClients(let old), .probeClients(let fresh)): .probeClients(StableOrder.merge(old, fresh, id: \.mac))
            case (.ble(let old), .ble(let fresh)): .ble(StableOrder.merge(old, fresh, id: \.address))
            default: new
            }
        }
    }

    var body: some View {
        List {
            switch rows {
            case .none:
                EmptyView()
            case .aps(let aps):
                ForEach(aps, id: \.bssid) { ap in
                    NavigationLink(value: DetailRoute.accessPoint(sessionID: sessionID, bssid: ap.bssid)) {
                        AccessPointRowView(ap: ap)
                    }
                    .listRowBackground(Theme.Colors.ground)
                }
            case .clients(let clients):
                ForEach(clients, id: \.client.mac) { item in
                    NavigationLink(value: DetailRoute.client(sessionID: sessionID, mac: item.client.mac)) {
                        ClientRowView(item: item)
                    }
                    .listRowBackground(Theme.Colors.ground)
                }
            case .probeNetworks(let networks):
                ForEach(networks, id: \.ssid) { network in
                    NavigationLink(value: DetailRoute.probeNetwork(sessionID: sessionID, ssid: network.ssid)) {
                        ProbeNetworkRowView(network: network)
                    }
                    .listRowBackground(Theme.Colors.ground)
                }
            case .probeClients(let clients):
                ForEach(clients, id: \.mac) { client in
                    NavigationLink(value: DetailRoute.client(sessionID: sessionID, mac: client.mac)) {
                        ProbeClientRowView(client: client)
                    }
                    .listRowBackground(Theme.Colors.ground)
                }
            case .ble(let devices):
                ForEach(devices, id: \.address) { device in
                    NavigationLink(value: DetailRoute.ble(sessionID: sessionID, address: device.address)) {
                        BLERowView(device: device)
                    }
                    .listRowBackground(Theme.Colors.ground)
                }
            }
            if rows.count > 0 {
                Text(footer)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.ink2)
                    .listRowBackground(Color.clear)
                    .frame(maxWidth: .infinity)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("lists.list")
        .onScrollPhaseChange { _, phase in
            scrolling = phase != .idle
            if !scrolling { applyPending() }
        }
        .onChange(of: isPaused) { _, paused in
            if !paused { applyPending() }
        }
        .overlay {
            if let failure {
                ContentUnavailableView("Could not read the survey", systemImage: "exclamationmark.triangle",
                                       description: Text(failure))
            } else if loaded && rows.count == 0 {
                if filters.search.isEmpty {
                    ContentUnavailableView {
                        Label(emptyTitle, systemImage: emptySymbol)
                    } description: {
                        Text(emptyMessage)
                    } actions: {
                        // A past survey without Bluetooth: the iPhone can still show what is near.
                        if kind == .ble && !filters.isFiltering(kind) && model.survey.state == .idle {
                            NearbyButton()
                        }
                    }
                } else {
                    ContentUnavailableView.search(text: filters.search)
                }
            }
        }
        .task(id: Shown(kind: kind, sessionID: sessionID, filters: filters)) {
            await observe()
        }
    }

    private func observe() async {
        let key = Shown(kind: kind, sessionID: sessionID, filters: filters)
        if shown?.kind != key.kind || shown?.sessionID != key.sessionID {
            // Another list: do not show the previous one's rows meanwhile.
            rows = .none
            loaded = false
        }
        pending = nil
        failure = nil
        let store = data.store
        let id = sessionID
        let query = filters.query(for: kind)
        do {
            switch kind {
            case .aps:
                for try await value in store.observe({ try StoreQueries.accessPoints($0, sessionID: id, query: query) }) {
                    receive(.aps(value), key: key)
                }
            case .clients:
                for try await value in store.observe({ try StoreQueries.clients($0, sessionID: id, query: query) }) {
                    receive(.clients(value), key: key)
                }
            case .probeNetworks:
                for try await value in store.observe({ try StoreQueries.probeNetworks($0, sessionID: id, query: query) }) {
                    receive(.probeNetworks(value), key: key)
                }
            case .probeClients:
                for try await value in store.observe({ try StoreQueries.probeClients($0, sessionID: id, query: query) }) {
                    receive(.probeClients(value), key: key)
                }
            case .ble:
                for try await value in store.observe({ try StoreQueries.bleDevices($0, sessionID: id, query: query) }) {
                    receive(.ble(value), key: key)
                }
            }
        } catch is CancellationError {
        } catch {
            failure = error.localizedDescription
        }
    }

    private func receive(_ value: Rows, key: Shown) {
        if shown != key {
            // New search, sort or filter: show its order right away.
            shown = key
            rows = value
            loaded = true
            lastReorder = .now
            return
        }
        pending = value
        if !scrolling && !isPaused { applyPending() }
    }

    private func applyPending() {
        guard let value = pending else { return }
        pending = nil
        if Date.now.timeIntervalSince(lastReorder) >= Self.reorderInterval {
            rows = value
            lastReorder = .now
        } else {
            rows = rows.merged(with: value)
        }
        loaded = true
    }

    private var footer: String {
        let count = rows.count
        if count >= ListFilters.rowLimit {
            return "Showing the first \(DataFormat.count(count)). Search or filter to narrow the list."
        }
        let noun = switch kind {
        case .aps: count == 1 ? "access point" : "access points"
        case .clients, .probeClients: count == 1 ? "client" : "clients"
        case .probeNetworks: count == 1 ? "network" : "networks"
        case .ble: count == 1 ? "Bluetooth device" : "Bluetooth devices"
        }
        return "\(DataFormat.count(count)) \(noun)"
    }

    private var emptyTitle: String {
        switch kind {
        case .aps: "No access points"
        case .clients: "No clients"
        case .probeNetworks, .probeClients: "No probe requests"
        case .ble: "No Bluetooth devices"
        }
    }

    private var emptySymbol: String {
        switch kind {
        case .ble: "dot.radiowaves.right"
        case .probeNetworks, .probeClients: "magnifyingglass"
        default: "wifi"
        }
    }

    private var emptyMessage: String {
        if filters.isFiltering(kind) { return "Nothing matches the filters." }
        return switch kind {
        case .aps: "Access points appear here as the survey hears their beacons."
        case .clients: "Clients appear here when Wi-Fi Clients is on in the Survey tab."
        case .probeNetworks, .probeClients: "Probe requests appear here when Wi-Fi Clients is on in the Survey tab."
        case .ble: "Bluetooth devices appear here when Bluetooth is on in the Survey tab."
        }
    }
}

nonisolated enum StableOrder {
    /// The rows of `new`, ordered as in `old` where they already exist,
    /// followed by rows that are new, in `new`'s order.
    static func merge<Row>(_ old: [Row], _ new: [Row], id: KeyPath<Row, String>) -> [Row] {
        var fresh = Dictionary(new.map { ($0[keyPath: id], $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Row] = []
        result.reserveCapacity(new.count)
        for row in old {
            if let updated = fresh.removeValue(forKey: row[keyPath: id]) { result.append(updated) }
        }
        for row in new where fresh[row[keyPath: id]] != nil {
            result.append(row)
            fresh.removeValue(forKey: row[keyPath: id])
        }
        return result
    }
}
