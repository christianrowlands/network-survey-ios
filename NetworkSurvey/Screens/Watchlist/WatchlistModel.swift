import Foundation
import Observation
import OSLog
import SurveyCore

/// The watchlist for the screens: the watched networks with their sighting
/// counts, kept current from the database, and the actions on them. Owned by
/// the app model so sightings turn into notifications even with no screen open
/// (a survey in the background).
@MainActor
@Observable
final class WatchlistModel {
    enum AddOutcome: Equatable {
        /// `alertsTurnedOn` when this add switched watchlist alerts on.
        case added(label: String, alertsTurnedOn: Bool)
        case duplicate
        case invalid
    }

    /// A network to add from a detail screen, prefilled (see `WatchlistAddSheet`).
    struct Draft: Identifiable {
        let id = UUID()
        var ssid: String
        var bssid: String
    }

    private(set) var summaries: [WatchlistEntrySummary] = []
    var draft: Draft?
    /// The user turned notifications off for the app; sightings are still recorded.
    private(set) var notificationsDenied = false

    @ObservationIgnored let store: SurveyStore
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let notifier: WatchlistNotifier
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    private static let log = Logger(subsystem: "app.networksurvey.ios", category: "watchlist")

    init(store: SurveyStore, settings: SettingsStore, monitor: WatchlistMonitor, notifier: WatchlistNotifier) {
        self.store = store
        self.settings = settings
        self.notifier = notifier
        let summaries = store.observe(WatchlistQueries.summaries)
        tasks.append(Task { [weak self] in
            do {
                for try await value in summaries { self?.summaries = value }
            } catch {
                Self.log.error("Watchlist not observed: \(error.localizedDescription, privacy: .public)")
            }
        })
        let sightings = monitor.sightings()
        tasks.append(Task { [notifier] in
            for await sighting in sightings { await notifier.post(sighting) }
        })
    }

    var entries: [WatchlistEntry] { summaries.map(\.entry) }

    /// The entry (enabled or not) that matches this network, if any.
    func entry(ssid: String?, bssid: String) -> WatchlistEntry? {
        entries.first { WatchlistMatcher.matches($0, ssid: ssid, bssid: bssid) }
    }

    func isWatched(ssid: String?, bssid: String) -> Bool {
        entry(ssid: ssid, bssid: bssid) != nil
    }

    /// The entry that watches this network name on any access point (no
    /// BSSID), for a probed network's details.
    func entry(network ssid: String) -> WatchlistEntry? {
        guard let wanted = WatchlistMatcher.normalizeSSID(ssid) else { return nil }
        return entries.first { entry in
            entry.bssid == nil
                && WatchlistMatcher.normalizeSSID(entry.ssid).map { $0.caseInsensitiveCompare(wanted) == .orderedSame } == true
        }
    }

    /// Some entry names this network, for a collapsed SSID group in the
    /// access point list. Entries that name only a BSSID show on the access
    /// point's own row once the group is open.
    func watchesNetwork(ssid: String) -> Bool {
        guard let wanted = WatchlistMatcher.normalizeSSID(ssid) else { return false }
        return entries.contains { entry in
            WatchlistMatcher.normalizeSSID(entry.ssid).map { $0.caseInsensitiveCompare(wanted) == .orderedSame } ?? false
        }
    }

    // MARK: - Changes

    /// Adds a network. `turnOnAlerts` (adding from a detail screen, where the
    /// alerts switch is out of sight) also turns watchlist alerts on. The first
    /// network added is when the app asks to send notifications.
    func add(label: String, ssid: String?, bssid: String?, turnOnAlerts: Bool) async -> AddOutcome {
        let result: WatchlistSaveResult
        do {
            result = try await store.addWatchlistEntry(label: label, ssid: ssid, bssid: bssid)
        } catch {
            Self.log.error("Watchlist entry not added: \(error.localizedDescription, privacy: .public)")
            return .invalid
        }
        switch result {
        case .saved(let entry):
            var turnedOn = false
            if turnOnAlerts && !settings[Settings.watchlistEnabled] {
                settings[Settings.watchlistEnabled] = true
                turnedOn = true
            }
            // Not awaited: the system may hold the prompt until a sheet closes.
            Task { await askForNotifications() }
            return .added(label: entry.label, alertsTurnedOn: turnedOn)
        case .duplicate: return .duplicate
        case .invalid: return .invalid
        }
    }

    func update(_ entry: WatchlistEntry, label: String, ssid: String?, bssid: String?) async -> WatchlistSaveResult {
        guard let id = entry.id else { return .invalid }
        return (try? await store.updateWatchlistEntry(id: id, label: label, ssid: ssid, bssid: bssid)) ?? .invalid
    }

    func setEnabled(_ entry: WatchlistEntry, _ enabled: Bool) {
        guard let id = entry.id else { return }
        Task { try? await store.setWatchlistEntry(id: id, enabled: enabled) }
    }

    func delete(_ entry: WatchlistEntry) {
        guard let id = entry.id else { return }
        Task { try? await store.deleteWatchlistEntry(id: id) }
        notifier.remove(entry)
    }

    func clearAll() {
        Task { try? await store.clearWatchlist() }
    }

    func clearHistory(entryID: Int64? = nil) {
        Task { try? await store.clearWatchlistHistory(entryID: entryID) }
    }

    // MARK: - Notifications

    /// Asks once, when there is something to be notified about.
    func askForNotifications() async {
        await notifier.requestAuthorizationIfNeeded()
        await refreshNotificationStatus()
    }

    func refreshNotificationStatus() async {
        notificationsDenied = await notifier.isDenied()
    }
}
