import BoardProtocol
import Foundation
import NSMessaging
import Synchronization

/// A watched network that just came into range.
public struct WatchlistSighting: Sendable, Equatable {
    /// The entry as it was when the network was seen.
    public var entry: WatchlistEntry
    /// The stored sighting (with its id once stored).
    public var hit: WatchlistHit
    /// The full fix, for the MQTT match message; nil without a location.
    public var location: LocationSample?
}

/// Watches the Scout's access points during a survey for networks on the
/// watchlist (see `WatchlistDetector` for when a network counts as newly
/// seen). Each sighting is stored in the history and then announced on
/// `sightings()`, which the app turns into a notification and MQTT into a
/// match message.
///
/// The record pipeline calls `observe` for every access point record. That
/// check runs in memory against a snapshot of the enabled entries, so it is
/// cheap; storing happens on a background task. Nothing is watched while the
/// `watchlist_enabled` setting is off.
public final class WatchlistMonitor: Sendable {
    private let store: SurveyStore
    private let settings: SettingsStore
    private let detector = Mutex(WatchlistDetector())
    private let broadcaster = Broadcaster<WatchlistSighting>()
    private let found: AsyncStream<WatchlistSighting>.Continuation
    private let refreshes: AsyncStream<Void>.Continuation
    private let tasks = Mutex<[Task<Void, Never>]>([])
    private let started = Mutex(false)

    public init(store: SurveyStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
        let (sightings, found) = AsyncStream.makeStream(of: WatchlistSighting.self)
        self.found = found
        let (triggers, refreshes) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.refreshes = refreshes
        let broadcaster = broadcaster
        // One task stores sightings in order; another applies entry and setting
        // changes one at a time, so an older read never replaces a newer one.
        let storing = Task {
            for await sighting in sightings {
                guard let hit = try? await store.insertWatchlistHit(sighting.hit) else { continue }
                var stored = sighting
                stored.hit = hit
                broadcaster.send(stored)
            }
        }
        let refreshing = Task { [weak self] in
            for await _ in triggers { await self?.refresh() }
        }
        tasks.withLock { $0 = [storing, refreshing] }
    }

    deinit {
        found.finish()
        refreshes.finish()
        tasks.withLock { $0.forEach { $0.cancel() } }
    }

    /// Follows entry and setting changes from now on and prunes sightings
    /// older than `WatchlistHit.retentionDays`. Later calls do nothing.
    public func start(now: Date = Date()) async {
        guard started.withLock({ value in defer { value = true }; return !value }) else { return }
        let entryChanges = store.observe { try WatchlistEntry.fetchAll($0) }
        let settingChanges = settings.changes()
        let refreshes = refreshes
        let watching = Task {
            do {
                for try await _ in entryChanges { refreshes.yield() }
            } catch {}
        }
        let following = Task {
            for await name in settingChanges where name == Settings.watchlistEnabled.name { refreshes.yield() }
        }
        tasks.withLock { $0 += [watching, following] }
        refreshes.yield()
        let cutoff = now.addingTimeInterval(-TimeInterval(WatchlistHit.retentionDays) * 86_400)
        _ = try? await store.pruneWatchlistHits(before: cutoff)
    }

    /// Re-reads the entries and the setting now (tests, or after a change the
    /// monitor cannot see).
    public func refresh() async {
        let entries = settings[Settings.watchlistEnabled] ? ((try? await store.watchlistEntries()) ?? []) : []
        detector.withLock { $0.setEntries(entries) }
    }

    /// Sightings as they are stored, for any number of subscribers.
    public func sightings() -> AsyncStream<WatchlistSighting> {
        broadcaster.stream()
    }

    /// Checks one access point record. `location` is where it was heard, or
    /// nil when it must not be kept (no fix, or inside a privacy zone).
    public func observe(
        _ ap: NSBApObservation, time: Date, receivedAt: Date, location: LocationSample?, missionId: String
    ) {
        let ssid = ap.ssidHidden ? "" : WifiFields.ssid(ap.ssid)
        let bssid = WifiFields.mac(ap.bssid)
        let alerts = detector.withLock { detector -> [WatchlistEntry] in
            detector.isEmpty ? [] : detector.observe(ssid: ssid, bssid: bssid, at: time, receivedAt: receivedAt)
        }
        for entry in alerts {
            guard let id = entry.id else { continue }
            let hit = WatchlistHit(
                entryId: id, label: entry.label, matchedField: entry.matchedField, ssid: ssid, bssid: bssid,
                rssi: ap.rssiLast < 0 ? Int(ap.rssiLast) : nil, latitude: location?.latitude,
                longitude: location?.longitude, timestamp: time, missionId: missionId
            )
            found.yield(WatchlistSighting(entry: entry, hit: hit, location: location))
        }
    }
}
