import BoardProtocol
import MapKit
import SurveyCore
import SwiftUI

/// Access points, clients and Bluetooth devices at their strongest positions,
/// with the optional track and the privacy zones.
struct MapScreen: View {
    @Environment(SurveyData.self) private var data
    @Environment(SettingsModel.self) private var settings
    @Environment(MapCommands.self) private var commands
    @State private var filters = MapFilters()
    @State private var points: [MapPoint] = []
    @State private var pointsVersion = 0
    @State private var track: [CLLocationCoordinate2D] = []
    @State private var viewport: Viewport?
    @State private var clusters: [MapCluster] = []
    @State private var position = MapCameraPosition.automatic
    @State private var editingZones = false
    @State private var editedZone: ZoneEdit?
    @State private var path = NavigationPath()

    /// How often the map takes new data from a running survey.
    static let refreshInterval = Duration.seconds(2)

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { geometry in
                MapReader { proxy in
                    Map(position: $position) {
                        if filters.showTrack && track.count > 1 {
                            MapPolyline(coordinates: track)
                                .stroke(Theme.Colors.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        }
                        ForEach(clusters) { cluster in
                            Annotation("", coordinate: cluster.coordinate) {
                                MapMarkerView(cluster: cluster) { select(cluster) }
                                    .opacity(editingZones ? 0.3 : 1)
                                    .allowsHitTesting(!editingZones)
                            }
                            .annotationTitles(.hidden)
                        }
                        ForEach(shownZones) { zone in
                            MapCircle(center: zone.center.coordinate, radius: zone.radiusMeters)
                                .foregroundStyle(Theme.Colors.red.opacity(0.15))
                                .stroke(Theme.Colors.red, lineWidth: 2)
                        }
                        if editingZones {
                            ForEach(shownZones) { zone in
                                Annotation(zone.name.isEmpty ? "Privacy zone" : zone.name, coordinate: zone.center.coordinate) {
                                    ZoneHandle(zone: zone) { editedZone = ZoneEdit(zone: zone, isNew: false) }
                                }
                            }
                        }
                        UserAnnotation()
                    }
                    .mapStyle(.standard(pointsOfInterest: .excludingAll))
                    .mapControls {
                        MapUserLocationButton()
                        MapCompass()
                        MapScaleView()
                    }
                    .onMapCameraChange(frequency: .onEnd) { context in
                        viewport = Viewport(context.region, size: geometry.size)
                    }
                    .simultaneousGesture(addZoneGesture(proxy), including: editingZones ? .all : .subviews)
                    .accessibilityIdentifier("map.map")
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if editingZones { zoneBanner } else { MapLegend(filters: $filters, points: points) }
            }
            .overlay {
                if data.sessionID == nil && !editingZones {
                    NoSurveyView(message: "Start a survey to see what was heard, placed where each signal was strongest.")
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
                        .padding(Theme.Spacing.xxl)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) { SessionTitle(title: "Map") }
                ToolbarItem(placement: .topBarTrailing) {
                    MapFilterMenu(filters: $filters) { editingZones = true }
                }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationDestination(for: DetailRoute.self) { DetailScreen(route: $0) }
            .sheet(item: $editedZone) { edit in
                PrivacyZoneEditor(zone: edit.zone, isNew: edit.isNew, units: settings[Settings.units]) { saveZone($0) } onDelete: {
                    deleteZone(edit.zone.id)
                }
                .presentationDetents([.medium, .large])
            }
            .task(id: PointsKey(sessionID: data.sessionID, filters: filters)) {
                await observePoints()
            }
            .task(id: ClusterInput(version: pointsVersion, viewport: viewport)) {
                await recluster()
            }
            .onChange(of: commands.editZones, initial: true) { _, requested in
                // Settings > Privacy zones > Add opens the map in zone mode.
                if requested {
                    editingZones = true
                    commands.editZones = false
                }
            }
        }
    }

    // MARK: - Points and clusters

    private struct PointsKey: Equatable {
        var sessionID: String?
        var filters: MapFilters
    }

    private struct ClusterInput: Equatable {
        var version: Int
        var viewport: Viewport?
    }

    /// Takes the latest points and track, then waits, so a busy survey
    /// redraws the map at most every `refreshInterval`.
    private func observePoints() async {
        guard let sessionID = data.sessionID else {
            points = []
            track = []
            pointsVersion += 1
            return
        }
        let kinds = filters.kinds
        let bands = filters.bands
        let showTrack = filters.showTrack
        let updates = data.store.observe { db -> ([MapPoint], [CLLocationCoordinate2D]) in
            let points = try StoreQueries.mapPoints(db, sessionID: sessionID, kinds: kinds, bands: bands)
            let track = showTrack ? try StoreQueries.trackPoints(db, sessionID: sessionID) : []
            let thinned = TrackThinner.thin(track).map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            return (points, thinned)
        }
        do {
            for try await (newPoints, newTrack) in updates {
                points = newPoints
                track = newTrack
                pointsVersion += 1
                try await Task.sleep(for: Self.refreshInterval)
            }
        } catch {}
    }

    /// Clusters off the main actor, only what is on screen (with a margin).
    private func recluster() async {
        let points = points
        let viewport = viewport
        let result = await Task.detached(priority: .userInitiated) {
            guard let viewport else {
                return MapClusterer.clusters(points, latitudeDelta: 0.02, longitudeDelta: 0.02,
                                             size: CGSize(width: 390, height: 700))
            }
            let visible = points.filter {
                abs($0.latitude - viewport.latitude) <= viewport.latitudeDelta
                    && abs($0.longitude - viewport.longitude) <= viewport.longitudeDelta
            }
            return MapClusterer.clusters(visible, latitudeDelta: viewport.latitudeDelta,
                                         longitudeDelta: viewport.longitudeDelta, size: viewport.size)
        }.value
        if !Task.isCancelled { clusters = result }
    }

    private func select(_ cluster: MapCluster) {
        if cluster.isSingle {
            let point = cluster.points[0]
            guard let sessionID = data.sessionID else { return }
            switch point.kind {
            case .ap: path.append(DetailRoute.accessPoint(sessionID: sessionID, bssid: point.identity))
            case .client, .probe: path.append(DetailRoute.client(sessionID: sessionID, mac: point.identity))
            case .ble: path.append(DetailRoute.ble(sessionID: sessionID, address: point.identity))
            }
        } else {
            let lats = cluster.points.map(\.latitude), lons = cluster.points.map(\.longitude)
            let span = MKCoordinateSpan(
                latitudeDelta: max((lats.max()! - lats.min()!) * 1.6, 0.0008),
                longitudeDelta: max((lons.max()! - lons.min()!) * 1.6, 0.0008)
            )
            withAnimation {
                position = .region(MKCoordinateRegion(center: cluster.coordinate, span: span))
            }
        }
    }

    // MARK: - Privacy zones

    private var zones: [PrivacyZone] { settings[Settings.privacyZones] }

    /// Saved zones plus a new one while its editor is open (saved only on Add).
    private var shownZones: [PrivacyZone] {
        guard let edit = editedZone, edit.isNew else { return zones }
        return zones + [edit.zone]
    }

    private var zoneBanner: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(Theme.Colors.red)
                .accessibilityHidden(true)
            Text("Touch and hold the map to add a privacy zone. Tap a zone's center to change or delete it.")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Colors.ink)
            Spacer(minLength: 0)
            Button("Done") { editingZones = false }
                .font(Theme.Fonts.sectionTitle)
                .accessibilityIdentifier("map.zonesDone")
        }
        .padding(Theme.Spacing.m)
        .background(.regularMaterial)
    }

    private func addZoneGesture(_ proxy: MapProxy) -> some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onEnded { value in
                guard editingZones, editedZone == nil, case .second(true, let drag?) = value,
                      let coordinate = proxy.convert(drag.location, from: .local) else { return }
                let zone = PrivacyZone(
                    name: "Zone \(zones.count + 1)",
                    center: GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude),
                    radiusMeters: defaultZoneRadius
                )
                editedZone = ZoneEdit(zone: zone, isNew: true)
            }
    }

    /// About a sixth of the visible width, so a new zone is easy to see.
    private var defaultZoneRadius: Double {
        guard let viewport else { return PrivacyZoneEditor.defaultRadius }
        let width = viewport.longitudeDelta * 111_320 * cos(viewport.latitude * .pi / 180)
        let range = PrivacyZoneEditor.radiusRange
        return min(max((width / 6 / 5).rounded() * 5, range.lowerBound), range.upperBound)
    }

    private func saveZone(_ zone: PrivacyZone) {
        var list = zones
        if let index = list.firstIndex(where: { $0.id == zone.id }) { list[index] = zone } else { list.append(zone) }
        settings[Settings.privacyZones] = list
    }

    private func deleteZone(_ id: UUID) {
        settings[Settings.privacyZones] = zones.filter { $0.id != id }
    }
}

/// A zone in the editor; new zones are not saved until the user adds them.
struct ZoneEdit: Identifiable {
    var zone: PrivacyZone
    var isNew: Bool
    var id: UUID { zone.id }
}

/// Requests from other screens to the Map.
@Observable
final class MapCommands {
    /// Open the Map in privacy zone editing.
    var editZones = false
}

/// The visible region and the map's size, for clustering.
nonisolated struct Viewport: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var latitudeDelta: Double
    var longitudeDelta: Double
    var size: CGSize

    init(_ region: MKCoordinateRegion, size: CGSize) {
        latitude = region.center.latitude
        longitude = region.center.longitude
        latitudeDelta = region.span.latitudeDelta
        longitudeDelta = region.span.longitudeDelta
        self.size = size
    }
}

private struct ZoneHandle: View {
    let zone: PrivacyZone
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "hand.raised.fill")
                .font(.footnote)
                .foregroundStyle(Theme.Colors.onAccent)
                .frame(width: 32, height: 32)
                .background(Theme.Colors.red, in: Circle())
                .overlay(Circle().stroke(Theme.Colors.panel, lineWidth: 2))
                .shadow(color: Theme.Colors.shadow, radius: 2, y: 1)
                .frame(width: Theme.Spacing.touchTarget, height: Theme.Spacing.touchTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Edit privacy zone \(zone.name)")
    }
}

extension GeoPoint {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
