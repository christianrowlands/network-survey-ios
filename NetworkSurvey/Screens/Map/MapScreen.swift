import BoardProtocol
import MapKit
import SurveyCore
import SwiftUI
import Towers

/// Access points, clients and Bluetooth devices at their strongest positions,
/// with the optional track, the privacy zones and the cell tower layer.
struct MapScreen: View {
    @Environment(SurveyData.self) private var data
    @Environment(SettingsModel.self) private var settings
    @Environment(MapCommands.self) private var commands
    @Environment(TowerLayerModel.self) private var towers
    @State private var filters = MapFilters()
    @State private var points: [MapPoint] = []
    @State private var pointsVersion = 0
    @State private var track: [CLLocationCoordinate2D] = []
    @State private var viewport: Viewport?
    @State private var clusters: [MapCluster<MapPoint>] = []
    @State private var position = MapCameraPosition.automatic
    @State private var editingZones = false
    @State private var editedZone: ZoneEdit?
    @State private var path = NavigationPath()
    @State private var towerClusters: [MapCluster<Tower>] = []
    @State private var towerSelection: TowerSelection?
    @State private var towerOrigin: CLLocationCoordinate2D?
    @State private var showingTowerFilters = false
    @State private var showingTowerSearch = false
    @State private var askingTowerNotice = false

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
                        TowerMapContent(
                            clusters: towerClusters, selection: towerSelection, origin: towerOrigin,
                            names: towers.operatorNames, units: settings[Settings.units], dimmed: editingZones,
                            onTap: selectTower
                        )
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
                    .mapStyle(settings[Settings.mapStyle] == .satellite
                        ? .hybrid(pointsOfInterest: .excludingAll) : .standard(pointsOfInterest: .excludingAll))
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
                VStack(spacing: 0) {
                    PastSurveyBar()
                    if editingZones { zoneBanner } else { MapLegend(filters: $filters, points: points, towers: towerLegend) }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if towersOn && !editingZones {
                    TowerStatusView(status: towers.status, source: settings[Settings.towerSource]) { towers.retry() }
                }
            }
            .overlay {
                // With towers on, the map is useful before any survey.
                if data.sessionID == nil && !editingZones && !towersOn {
                    NoSurveyView(message: "Start a survey to see what was heard, placed where each signal was strongest.")
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
                        .padding(Theme.Spacing.xxl)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) { SessionTitle(title: "Map") }
                ToolbarItem(placement: .topBarTrailing) {
                    MapFilterMenu(
                        filters: $filters, satellite: satelliteBinding, towersOn: towersOn,
                        onEditZones: { editingZones = true }, onTowerFilters: { showingTowerFilters = true },
                        onFindTower: { showingTowerSearch = true }
                    )
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
            .modifier(TowerSheets(
                selection: $towerSelection, showingFilters: $showingTowerFilters, showingSearch: $showingTowerSearch,
                askingNotice: $askingTowerNotice, onFound: showFound, onAcceptNotice: {
                    settings[Settings.hasSeenTowerNotice] = true
                    settings[Settings.showTowers] = true
                }
            ))
            .task(id: towerRequest) {
                // Waits for the map to settle; a newer camera or filter cancels this.
                guard let towerRequest else { return }
                try? await Task.sleep(for: .milliseconds(500))
                if !Task.isCancelled { towers.show(towerRequest) }
            }
            .task(id: TowerClusterInput(version: towers.visibleVersion, viewport: viewport, selection: towerSelection?.id)) {
                await reclusterTowers()
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

    private func select(_ cluster: MapCluster<MapPoint>) {
        if cluster.isSingle {
            let point = cluster.points[0]
            guard let sessionID = data.sessionID else { return }
            switch point.kind {
            case .ap: path.append(DetailRoute.accessPoint(sessionID: sessionID, bssid: point.identity))
            case .client, .probe: path.append(DetailRoute.client(sessionID: sessionID, mac: point.identity))
            case .ble: path.append(DetailRoute.ble(sessionID: sessionID, address: point.identity))
            }
        } else {
            zoom(to: cluster.points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
                 around: cluster.coordinate)
        }
    }

    /// Zooms in until a group's members are spread across the view.
    private func zoom(to coordinates: [CLLocationCoordinate2D], around center: CLLocationCoordinate2D) {
        let lats = coordinates.map(\.latitude), lons = coordinates.map(\.longitude)
        let span = MKCoordinateSpan(
            latitudeDelta: max((lats.max()! - lats.min()!) * 1.6, 0.0008),
            longitudeDelta: max((lons.max()! - lons.min()!) * 1.6, 0.0008)
        )
        withAnimation {
            position = .region(MKCoordinateRegion(center: center, span: span))
        }
    }

    // MARK: - Towers

    private struct TowerClusterInput: Equatable {
        var version: Int
        var viewport: Viewport?
        var selection: String?
    }

    private var towersOn: Bool { settings[Settings.showTowers] }

    private var towerRequest: TowerLayerModel.Request? {
        viewport.map {
            TowerLayerModel.Request(
                view: GeoBounds(latitude: $0.latitude, longitude: $0.longitude,
                                latitudeDelta: $0.latitudeDelta, longitudeDelta: $0.longitudeDelta),
                filters: settings.towerFilters, enabled: towersOn
            )
        }
    }

    private var towerLegend: TowerLegendItem {
        TowerLegendItem(isOn: towersOn, count: towerClusters.reduce(0) { $0 + $1.points.count }, toggle: toggleTowers) {
            showingTowerFilters = true
        }
    }

    private var satelliteBinding: Binding<Bool> {
        Binding(
            get: { settings[Settings.mapStyle] == .satellite },
            set: { settings[Settings.mapStyle] = $0 ? .satellite : .standard }
        )
    }

    /// The first time, explains what the layer sends before turning it on.
    private func toggleTowers() {
        if towersOn {
            settings[Settings.showTowers] = false
        } else if settings[Settings.hasSeenTowerNotice] {
            settings[Settings.showTowers] = true
        } else {
            askingTowerNotice = true
        }
    }

    /// Clusters the towers in view, leaving out the selected ones, which are
    /// drawn on their own.
    private func reclusterTowers() async {
        let selected = Set(towerSelection?.towers.map(\.id) ?? [])
        let towers = towers.visible.filter { !selected.contains($0.id) }
        guard let viewport, !towers.isEmpty else {
            towerClusters = []
            return
        }
        let result = await Task.detached(priority: .userInitiated) {
            let shown = towers.filter {
                abs($0.lat - viewport.latitude) <= viewport.latitudeDelta
                    && abs($0.lon - viewport.longitude) <= viewport.longitudeDelta
            }
            return MapClusterer.clusters(shown, latitudeDelta: viewport.latitudeDelta,
                                         longitudeDelta: viewport.longitudeDelta, size: viewport.size)
        }.value
        if !Task.isCancelled { towerClusters = result }
    }

    private func selectTower(_ cluster: MapCluster<Tower>) {
        if cluster.isSingle || cluster.isStack {
            towerOrigin = CLLocationManager().location?.coordinate
            towerSelection = TowerSelection(towers: cluster.points)
        } else {
            zoom(to: cluster.points.map(\.coordinate), around: cluster.coordinate)
        }
    }

    /// Moves to what a search found and shows it, with its range in view.
    private func showFound(_ found: [Tower]) {
        guard let tower = found.first else { return }
        towerOrigin = CLLocationManager().location?.coordinate
        towerSelection = TowerSelection(towers: found)
        let meters = max(Double(tower.range) * 2.5, 1500)
        withAnimation {
            position = .region(MKCoordinateRegion(center: tower.coordinate, latitudinalMeters: meters, longitudinalMeters: meters))
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
