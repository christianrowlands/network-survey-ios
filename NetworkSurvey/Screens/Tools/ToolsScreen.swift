import SurveyCore
import SwiftUI

/// What works apart from starting a survey: this iPhone's own Bluetooth, the
/// watchlist, the Wi-Fi spectrum of the shown survey, and offline lookups.
struct ToolsScreen: View {
    @Environment(AppModel.self) private var app
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Group {
                    Section {
                        nearbyRow
                    } footer: {
                        Text("Nearby Bluetooth uses this iPhone's own radio. Nothing it shows is saved, mapped or sent.")
                    }
                    Section {
                        NavigationLink(value: ToolsRoute.watchlist) {
                            ToolRow(title: "Watchlist", symbol: "eye", detail: watchlistDetail)
                        }
                        .accessibilityIdentifier("tools.watchlist")
                        NavigationLink(value: ToolsRoute.spectrum) {
                            ToolRow(title: "Wi-Fi spectrum", symbol: "chart.xyaxis.line",
                                    detail: "How busy each channel is in the shown survey")
                        }
                        .accessibilityIdentifier("tools.spectrum")
                    } header: {
                        Text("With a Scout")
                    }
                    Section {
                        NavigationLink(value: ToolsRoute.ouiLookup) {
                            ToolRow(title: "OUI lookup", symbol: "magnifyingglass",
                                    detail: "Who made a device, from its MAC address")
                        }
                        .accessibilityIdentifier("tools.ouiLookup")
                        NavigationLink(value: ToolsRoute.plmnLookup) {
                            ToolRow(title: "PLMN lookup", symbol: "antenna.radiowaves.left.and.right",
                                    detail: "Which carrier a mobile network code belongs to")
                        }
                        .accessibilityIdentifier("tools.plmnLookup")
                    } header: {
                        Text("Look up")
                    }
                }
                .panelRows()
            }
            .themedList()
            .navigationTitle("Tools")
            .navigationDestination(for: ToolsRoute.self) { route in
                switch route {
                case .watchlist: WatchlistScreen()
                case .spectrum: SpectrumScreen { path.append($0) }
                case .ouiLookup: OUILookupView()
                case .plmnLookup: PlmnLookupView()
                }
            }
            .navigationDestination(for: DetailRoute.self) { route in
                DetailScreen(route: route)
            }
            .onChange(of: app.toolsRoute, initial: true) { _, route in
                // Another screen asked for a page (a watchlist link).
                guard let route else { return }
                path = NavigationPath([route])
                app.toolsRoute = nil
            }
        }
    }

    /// Dimmed, not hidden, while a survey records: Nearby is kept apart from
    /// survey data, so it can't open then (and closes when one starts).
    private var nearbyRow: some View {
        let recording = app.survey.state != .idle
        return Button {
            app.showingNearby = true
        } label: {
            ToolRow(title: "Nearby Bluetooth", symbol: "iphone",
                    detail: recording ? "Not available while a survey records" : "What this iPhone hears. Not saved.",
                    showsChevron: true)
        }
        .disabled(recording)
        .accessibilityHint(recording ? "" : "Shows Bluetooth devices this iPhone hears, outside a survey")
        .accessibilityIdentifier("tools.nearby")
    }

    private var watchlistDetail: String {
        let count = app.watchlist.summaries.count
        let networks = count == 0 ? "No watched networks" : DataFormat.count(count, "watched network")
        // Sightings come from what a Scout hears during a survey.
        return app.boardsInUse.isEmpty ? "\(networks). Alerts need an NS Scout." : networks
    }
}

/// A tool: icon, name and one line saying what it does or holds.
private struct ToolRow: View {
    let title: String
    let symbol: String
    let detail: String
    /// For a row that is a button rather than a navigation link.
    var showsChevron = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.Colors.accent)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(title)
                    .foregroundStyle(Theme.Colors.ink)
                Text(detail)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.ink2)
            }
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(Theme.Fonts.caption.weight(.semibold))
                    .foregroundStyle(Theme.Colors.ink3)
                    .accessibilityHidden(true)
            }
        }
        .opacity(isEnabled ? 1 : 0.5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
