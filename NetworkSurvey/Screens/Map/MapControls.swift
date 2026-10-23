import BoardProtocol
import SurveyCore
import SwiftUI

struct MapFilters: Equatable {
    var kinds: Set<ObservationKind> = [.ap, .client, .ble]
    var bands: Set<NSBBand> = []
    var showTrack = true

    var isFiltering: Bool { !bands.isEmpty || !showTrack }
}

/// The legend at the top of the map, with counts, doubling as the type filter.
struct MapLegend: View {
    @Binding var filters: MapFilters
    let points: [MapPoint]

    var body: some View {
        let counts = Dictionary(grouping: points, by: \.kind).mapValues(\.count)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                chip(.ap, "APs", count: counts[.ap])
                chip(.client, "Clients", count: counts[.client])
                chip(.ble, "BLE", count: counts[.ble])
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

struct MapFilterMenu: View {
    @Binding var filters: MapFilters
    let onEditZones: () -> Void

    var body: some View {
        Menu {
            Button(action: onEditZones) {
                Label("Edit privacy zones", systemImage: "hand.raised")
            }
            .menuActionDismissBehavior(.enabled)
            .accessibilityIdentifier("map.zones")
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
