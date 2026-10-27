import BoardProtocol
import SurveyCore
import SwiftUI

struct MapFilters: Equatable {
    var kinds: Set<ObservationKind> = [.ap, .client, .ble]
    var bands: Set<NSBBand> = []
    var showTrack = true

    var isFiltering: Bool { !bands.isEmpty || !showTrack }
}

/// The tower layer's chip in the legend.
struct TowerLegendItem {
    var isOn: Bool
    var count: Int
    var toggle: () -> Void
    var openFilters: () -> Void
}

/// The legend at the top of the map, with counts, doubling as the type filter.
struct MapLegend: View {
    @Binding var filters: MapFilters
    let points: [MapPoint]
    var towers: TowerLegendItem?

    var body: some View {
        let counts = Dictionary(grouping: points, by: \.kind).mapValues(\.count)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                chip(.ap, "APs", count: counts[.ap])
                chip(.client, "Clients", count: counts[.client])
                chip(.ble, "BLE", count: counts[.ble])
                if let towers { towerChips(towers) }
            }
            .padding(.horizontal, Theme.Spacing.screenGutter)
            .padding(.vertical, Theme.Spacing.s)
        }
        .background(.regularMaterial)
    }

    private func chip(_ kind: ObservationKind, _ title: String, count: Int?) -> some View {
        let isOn = filters.kinds.contains(kind)
        return Button {
            if isOn { filters.kinds.remove(kind) } else { filters.kinds.insert(kind) }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Circle()
                    .fill(isOn ? MapMarkerView.color(kind) : Color.clear)
                    .overlay(Circle().stroke(MapMarkerView.color(kind), lineWidth: 1.5))
                    .frame(width: 10, height: 10)
                Text(isOn ? "\(title) \(DataFormat.count(count ?? 0))" : title)
                    .font(Theme.Fonts.label.monospacedDigit())
                    .foregroundStyle(isOn ? Theme.Colors.ink : Theme.Colors.ink2)
            }
            .padding(.horizontal, Theme.Spacing.m)
            .frame(minHeight: 32)
            .background(isOn ? Theme.Colors.panel : Theme.Colors.panel.opacity(0.5), in: Capsule())
            .overlay(Capsule().stroke(Theme.Colors.rule, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(MapMarkerView.kindName(kind, count: 2).capitalized)
        .accessibilityValue(isOn ? "Shown, \(count ?? 0)" : "Hidden")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("map.legend.\(kind.rawValue)")
    }
}

extension MapLegend {
    /// The Towers chip turns the layer on and off; once on, a second button
    /// opens its filters.
    @ViewBuilder
    func towerChips(_ towers: TowerLegendItem) -> some View {
        Button(action: towers.toggle) {
            HStack(spacing: Theme.Spacing.xs) {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(towers.isOn ? Theme.Colors.cellular : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 2.5).stroke(Theme.Colors.cellular, lineWidth: 1.5))
                    .frame(width: 10, height: 10)
                Text(towers.isOn ? "Towers \(DataFormat.count(towers.count))" : "Towers")
                    .font(Theme.Fonts.label.monospacedDigit())
                    .foregroundStyle(towers.isOn ? Theme.Colors.ink : Theme.Colors.ink2)
            }
            .padding(.horizontal, Theme.Spacing.m)
            .frame(minHeight: 32)
            .background(towers.isOn ? Theme.Colors.panel : Theme.Colors.panel.opacity(0.5), in: Capsule())
            .overlay(Capsule().stroke(Theme.Colors.rule, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cell towers")
        .accessibilityValue(towers.isOn ? "Shown, \(towers.count)" : "Hidden")
        .accessibilityAddTraits(towers.isOn ? .isSelected : [])
        .accessibilityIdentifier("map.legend.towers")
        if towers.isOn {
            Button(action: towers.openFilters) {
                Image(systemName: "slider.horizontal.3")
                    .font(Theme.Fonts.label)
                    .foregroundStyle(Theme.Colors.ink)
                    .frame(width: 32, height: 32)
                    .background(Theme.Colors.panel, in: Circle())
                    .overlay(Circle().stroke(Theme.Colors.rule, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tower filters")
            .accessibilityIdentifier("map.towers.filters")
        }
    }
}

struct MapFilterMenu: View {
    @Binding var filters: MapFilters
    @Binding var satellite: Bool
    let towersOn: Bool
    let onEditZones: () -> Void
    let onTowerFilters: () -> Void
    let onFindTower: () -> Void

    var body: some View {
        Menu {
            Button(action: onEditZones) {
                Label("Edit privacy zones", systemImage: "hand.raised")
            }
            .menuActionDismissBehavior(.enabled)
            .accessibilityIdentifier("map.zones")
            Divider()
            if towersOn {
                Button(action: onTowerFilters) {
                    Label("Tower filters", systemImage: "slider.horizontal.3")
                }
                .menuActionDismissBehavior(.enabled)
                .accessibilityIdentifier("map.towers.filters.menu")
            }
            Button(action: onFindTower) {
                Label("Find a tower", systemImage: "magnifyingglass")
            }
            .menuActionDismissBehavior(.enabled)
            .accessibilityIdentifier("map.towers.search")
            Divider()
            Toggle("Satellite", isOn: $satellite)
            Toggle("Show my track", isOn: $filters.showTrack)
            Section("Wi-Fi band (hides Bluetooth)") {
                ForEach(DataFormat.filterBands, id: \.self) { band in
                    Toggle(DataFormat.band(band.rawValue), isOn: Binding(
                        get: { filters.bands.contains(band) },
                        set: { if $0 { filters.bands.insert(band) } else { filters.bands.remove(band) } }
                    ))
                }
            }
        } label: {
            Label("Map options", systemImage: filters.isFiltering
                ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .menuActionDismissBehavior(.disabled)
        .accessibilityIdentifier("map.filter")
    }
}
