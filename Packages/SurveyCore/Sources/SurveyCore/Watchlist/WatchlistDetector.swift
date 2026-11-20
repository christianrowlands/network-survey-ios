import Foundation

/// Decides when a watched network counts as newly seen, the way the Network
/// Survey Android app does, so alerts do not repeat on every scan:
///
/// - An entry alerts when its network appears after being absent. It counts as
///   absent once it has not been seen for `absenceWindow` (60 s), so an access
///   point that drops out of a scan or two does not alert again.
/// - After an alert, the same entry does not alert again for its cooldown
///   (15 minutes by default), whatever happens.
/// - A record heard more than `lateThreshold` (5 s) before it arrived is a
///   Scout catching up on a backlog; it says nothing about what is here now
///   and is skipped.
///
/// Only enabled entries are watched. Pure state, so the rules are tested
/// without a database or clock.
public struct WatchlistDetector: Sendable {
    public static let absenceWindow: TimeInterval = 60
    public static let lateThreshold: TimeInterval = 5

    struct Presence: Sendable {
        var lastSeen: Date
        var lastAlert: Date?
    }

    private(set) var entries: [WatchlistEntry] = []
    private var presence: [Int64: Presence] = [:]
    private let absenceWindow: TimeInterval

    public init(entries: [WatchlistEntry] = [], absenceWindow: TimeInterval = Self.absenceWindow) {
        self.absenceWindow = absenceWindow
        setEntries(entries)
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Replaces what is watched. Presence is kept for entries that stay, so an
    /// edit elsewhere in the list does not re-alert a network in range.
    public mutating func setEntries(_ newEntries: [WatchlistEntry]) {
        entries = newEntries.filter { $0.enabled && $0.id != nil }
        let ids = Set(entries.compactMap(\.id))
        presence = presence.filter { ids.contains($0.key) }
    }

    /// The entries that alert for this access point heard at `time`.
    public mutating func observe(ssid: String, bssid: String, at time: Date, receivedAt: Date) -> [WatchlistEntry] {
        guard !entries.isEmpty, receivedAt.timeIntervalSince(time) <= Self.lateThreshold else { return [] }
        var alerts: [WatchlistEntry] = []
        for entry in entries where WatchlistMatcher.matches(entry, ssid: ssid, bssid: bssid) {
            guard let id = entry.id else { continue }
            var state = presence[id] ?? Presence(lastSeen: .distantPast, lastAlert: nil)
            let wasPresent = time.timeIntervalSince(state.lastSeen) < absenceWindow
            state.lastSeen = max(state.lastSeen, time)
            if !wasPresent {
                let cooldown = TimeInterval(max(entry.cooldownSeconds, 0))
                if state.lastAlert.map({ time.timeIntervalSince($0) >= cooldown }) ?? true {
                    state.lastAlert = time
                    alerts.append(entry)
                }
            }
            presence[id] = state
        }
        return alerts
    }
}
