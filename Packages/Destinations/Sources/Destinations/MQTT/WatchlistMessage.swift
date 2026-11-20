import NSMessaging

/// A Wi-Fi watchlist message for MQTT, outside the survey record flow. The
/// topics and JSON are the Network Survey Android app's.
public enum WatchlistMessage: Sendable {
    /// `watchlist_match_message`
    case match(WatchlistMatch)
    /// `watchlist_entry_message`
    case entries(WatchlistEntryUpdate)
}
