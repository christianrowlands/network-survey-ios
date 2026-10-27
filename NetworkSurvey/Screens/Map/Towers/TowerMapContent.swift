import CoreLocation
import MapKit
import SurveyCore
import SwiftUI
import Towers

/// The tower layer inside the map: clustered markers, and for the selected
/// tower its range and a dashed line from the user with the distance.
struct TowerMapContent: MapContent {
    let clusters: [MapCluster<Tower>]
    let selection: TowerSelection?
    /// Where the user was when the tower was picked.
    let origin: CLLocationCoordinate2D?
    let names: [Plmn: PlmnInfo]
    let units: DisplayUnits
    let dimmed: Bool
    let onTap: (MapCluster<Tower>) -> Void

    var body: some MapContent {
        if let tower = selection?.towers.first {
            if tower.range > 0 {
                MapCircle(center: tower.coordinate, radius: CLLocationDistance(tower.range))
                    .foregroundStyle(Theme.Colors.cellular.opacity(0.12))
                    .stroke(Theme.Colors.cellular, lineWidth: 1.5)
            }
            if let origin {
                MapPolyline(coordinates: [origin, tower.coordinate])
                    .stroke(Theme.Colors.cellular, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 5]))
                Annotation("", coordinate: midpoint(origin, tower.coordinate)) {
                    Text(DataFormat.distance(distance(origin, tower.coordinate), units: units))
                        .font(Theme.Fonts.label.monospacedDigit())
                        .foregroundStyle(Theme.Colors.ink)
                        .padding(.horizontal, Theme.Spacing.s)
                        .padding(.vertical, Theme.Spacing.xxs)
                        .background(.regularMaterial, in: Capsule())
                        .accessibilityLabel("Distance to the tower")
                        .accessibilityValue(DataFormat.distance(distance(origin, tower.coordinate), units: units))
                }
                .annotationTitles(.hidden)
            }
        }
        ForEach(clusters) { cluster in
            Annotation("", coordinate: cluster.coordinate) {
                TowerMarkerView(cluster: cluster, names: names) { onTap(cluster) }
                    .opacity(dimmed ? 0.3 : 1)
                    .allowsHitTesting(!dimmed)
            }
            .annotationTitles(.hidden)
        }
        // The pick stays out of the clusters (and may be a search result
        // outside the filters), so it is drawn on its own, on top.
        if let selection {
            let cluster = MapCluster(id: "selected", coordinate: selection.towers[0].coordinate, points: selection.towers)
            Annotation("", coordinate: cluster.coordinate) {
                TowerMarkerView(cluster: cluster, names: names) { onTap(cluster) }
                    .scaleEffect(1.25)
            }
            .annotationTitles(.hidden)
        }
    }

    private func midpoint(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: (a.latitude + b.latitude) / 2, longitude: (a.longitude + b.longitude) / 2)
    }

    private func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}

/// A line at the bottom of the map while the tower layer is on: what it is
/// doing, and whose data it shows.
struct TowerStatusView: View {
    let status: TowerLayerModel.Status
    let source: TowerSource
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            if let message {
                Button(action: onRetry) {
                    HStack(spacing: Theme.Spacing.s) {
                        if status == .loading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: symbol).accessibilityHidden(true)
                        }
                        Text(message)
                    }
                    .font(Theme.Fonts.label)
                    .foregroundStyle(Theme.Colors.ink)
                    .padding(.horizontal, Theme.Spacing.m)
                    .frame(minHeight: 32)
                    .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(status != .failed)
                .accessibilityIdentifier("map.towers.status")
            }
            Link(destination: source == .openCelliD ? Links.openCelliD : Links.btSearch) {
                Text(source == .openCelliD ? "Towers: OpenCelliD, CC BY-SA 4.0" : "Towers: BTSearch")
                    .font(.caption2)
                    .foregroundStyle(Theme.Colors.ink2)
                    .padding(.horizontal, Theme.Spacing.s)
                    .padding(.vertical, Theme.Spacing.xxs)
                    .background(.thinMaterial, in: Capsule())
            }
            .accessibilityIdentifier("map.towers.attribution")
        }
        .padding(.bottom, Theme.Spacing.s)
        .frame(maxWidth: .infinity)
    }

    private var message: String? {
        switch status {
        case .off, .ready: nil
        case .missingKey: "This build has no tower service key"
        case .zoomIn: "Zoom in to see towers"
        case .loading: "Loading towers"
        case .empty: "No towers here with these filters"
        case .truncated: "Not every tower here is shown. Zoom in for the rest."
        case .failed: "Couldn't load towers. Tap to try again."
        }
    }

    private var symbol: String {
        switch status {
        case .failed: "exclamationmark.triangle"
        case .zoomIn: "plus.magnifyingglass"
        case .missingKey: "key"
        default: "antenna.radiowaves.left.and.right"
        }
    }
}
