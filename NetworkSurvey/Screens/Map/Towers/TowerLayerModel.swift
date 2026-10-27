import Foundation
import SurveyCore
import Towers

/// The tower layer's data: fetches the towers in view from the NS Tower
/// Service through the session cache, at most one request at a time.
@Observable
final class TowerLayerModel {
    enum Status: Equatable {
        case off, missingKey, zoomIn, loading, ready, empty, truncated, failed
    }

    /// What the map shows and asks for.
    struct Request: Equatable {
        var view: GeoBounds
        var filters: TowerFilters
        var enabled: Bool
    }

    /// Cached towers in and around the view, to draw.
    private(set) var visible: [Tower] = []
    /// Changes whenever `visible` does, for reclustering.
    private(set) var visibleVersion = 0
    private(set) var status = Status.off
    /// Operator names, looked up as new operators appear.
    private(set) var operatorNames: [Plmn: PlmnInfo] = [:]
    /// Operators among the towers fetched, for the operator filter.
    private(set) var operatorsSeen: Set<Plmn> = []

    let client: TowerClient
    @ObservationIgnored private let cache = TowerTileCache()
    @ObservationIgnored private var request: Request?
    @ObservationIgnored private var cacheFilters: TowerFilters?
    @ObservationIgnored private var fetching = false
    /// The request that last failed: not retried until the view or filters change.
    @ObservationIgnored private var failedRequest: Request?
    @ObservationIgnored private var namesRequested: Set<Plmn> = []
    @ObservationIgnored private var shownVersion = -1
    @ObservationIgnored private var shownView: GeoBounds?

    init(client: TowerClient) {
        self.client = client
    }

    var hasKey: Bool { client.config.hasKey }

    func show(_ request: Request) {
        self.request = request
        update()
    }

    /// Tries a failed request again.
    func retry() {
        failedRequest = nil
        update()
    }

    func name(of plmn: Plmn) -> String? { operatorNames[plmn]?.name }

    private func update() {
        guard let request else { return }
        guard request.enabled else { return settle(.off, clear: true) }
        guard hasKey else { return settle(.missingKey, clear: true) }
        if request.filters != cacheFilters {
            cache.removeAll()
            cacheFilters = request.filters
        }
        guard !request.filters.technologies.isEmpty else { return settle(.empty, clear: true) }
        let view = request.view.clampedToWorld
        guard view.isQueryable, view.approximateArea <= TowerFetchPlanner.maxViewArea else {
            return settle(.zoomIn, clear: true)
        }

        let tiles = TileKey.covering(view)
        publish(around: view)
        guard !fetching else { return settle(.loading) }
        if failedRequest == request { return settle(.failed) }
        let gaps = cache.gaps(in: tiles, requestArea: view.approximateArea, now: .now)
        guard let box = TowerFetchPlanner.plan(visible: tiles, gaps: gaps) else {
            let status: Status = cache.hasIncomplete(in: tiles) ? .truncated : cache.towerCount(in: tiles) == 0 ? .empty : .ready
            return settle(status)
        }
        fetch(box, for: request)
    }

    private func fetch(_ box: GeoBounds, for request: Request) {
        fetching = true
        settle(.loading)
        let client = client
        Task {
            let result: Result<TowerBatch, TowerServiceError>
            do throws(TowerServiceError) {
                result = .success(try await client.towers(in: box, filters: request.filters))
            } catch {
                result = .failure(error)
            }
            fetching = false
            switch result {
            case .success(let batch):
                // Filters changed while waiting: these towers no longer apply.
                if request.filters == cacheFilters {
                    cache.ingest(box, towers: batch.towers, truncated: batch.truncated, now: .now)
                    lookUpNames(batch.towers)
                }
                failedRequest = nil
            case .failure:
                failedRequest = self.request
            }
            update()
        }
    }

    private func settle(_ status: Status, clear: Bool = false) {
        if clear && !visible.isEmpty {
            visible = []
            visibleVersion += 1
            shownVersion = -1
        }
        if self.status != status { self.status = status }
    }

    /// Towers within half a view of the edges, so a short pan has them ready.
    private func publish(around view: GeoBounds) {
        guard cache.version != shownVersion || view != shownView else { return }
        let latMargin = (view.north - view.south) / 2, lonMargin = (view.east - view.west) / 2
        let area = GeoBounds(south: view.south - latMargin, west: view.west - lonMargin,
                             north: view.north + latMargin, east: view.east + lonMargin)
        visible = cache.towers.filter { area.contains(latitude: $0.lat, longitude: $0.lon) }
        visibleVersion += 1
        shownVersion = cache.version
        shownView = view
    }

    private func lookUpNames(_ towers: [Tower]) {
        let plmns = Set(towers.map(\.plmn))
        let added = plmns.subtracting(operatorsSeen)
        if !added.isEmpty { operatorsSeen.formUnion(added) }
        let unnamed = plmns.subtracting(namesRequested)
        guard !unnamed.isEmpty else { return }
        namesRequested.formUnion(unnamed)
        let client = client
        Task {
            guard let names = try? await client.operators(unnamed.sorted()) else {
                namesRequested.subtract(unnamed)
                return
            }
            operatorNames.merge(names) { $1 }
        }
    }
}

extension GeoBounds {
    /// The part of the box on the map's single copy of the world (MapKit can
    /// report longitudes past 180 near the antimeridian).
    var clampedToWorld: GeoBounds {
        GeoBounds(south: max(south, -85), west: max(west, -180), north: min(north, 85), east: min(east, 180))
    }
}

extension SettingsModel {
    /// The tower filters as the settings hold them.
    var towerFilters: TowerFilters {
        TowerFilters(
            technologies: self[Settings.towerTechnologies],
            plmn: Plmn(string: self[Settings.towerOperator]),
            source: self[Settings.towerSource],
            maxAge: TowerAge(months: self[Settings.towerMaxAgeMonths])
        )
    }
}

extension TowerServiceConfig {
    /// The key and identity this build was made with (see Config/Base.xcconfig).
    static func app(bundle: Bundle = .main) -> TowerServiceConfig {
        TowerServiceConfig(
            apiKey: bundle.object(forInfoDictionaryKey: "NSTowerAPIKey") as? String ?? "",
            bundleID: bundle.bundleIdentifier ?? "app.networksurvey.ios",
            appVersion: bundle.shortVersion
        )
    }
}
