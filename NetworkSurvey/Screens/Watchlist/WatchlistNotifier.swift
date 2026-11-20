import Foundation
import SurveyCore
import UserNotifications

/// Local notifications for watched networks. One notification per watched
/// network: a later sighting replaces the earlier one instead of stacking.
/// How often they come is decided by `WatchlistDetector` (when a network
/// reappears, at most once per cooldown), as on Android. Tapping one opens the
/// watchlist history.
final class WatchlistNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let category = "watchlist"
    /// Called when a notification is tapped.
    var onOpen: (() -> Void)?
    /// False in unit tests, where nobody can answer the system prompt.
    var asksForPermission = true

    private var center: UNUserNotificationCenter { .current() }

    /// Becomes the delegate so notifications also show while the app is open.
    func activate() {
        center.delegate = self
    }

    func requestAuthorizationIfNeeded() async {
        guard asksForPermission, await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func isDenied() async -> Bool {
        await center.notificationSettings().authorizationStatus == .denied
    }

    func post(_ sighting: WatchlistSighting) async {
        let content = UNMutableNotificationContent()
        content.title = "Watched network nearby"
        content.body = Self.body(label: sighting.hit.label, rssi: sighting.hit.rssi)
        content.sound = .default
        content.threadIdentifier = Self.category
        content.userInfo = ["watchlistEntry": sighting.entry.uuid]
        let request = UNNotificationRequest(identifier: Self.identifier(sighting.entry), content: content, trigger: nil)
        try? await center.add(request)
    }

    /// A removed network's notification goes with it.
    func remove(_ entry: WatchlistEntry) {
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier(entry)])
    }

    nonisolated static func body(label: String, rssi: Int?) -> String {
        rssi.map { "\(label) is nearby (\($0) dBm)" } ?? "\(label) is nearby"
    }

    nonisolated static func identifier(_ entry: WatchlistEntry) -> String {
        "watchlist.\(entry.uuid)"
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.identifier.hasPrefix("watchlist.") else { return }
        await MainActor.run { onOpen?() }
    }
}
