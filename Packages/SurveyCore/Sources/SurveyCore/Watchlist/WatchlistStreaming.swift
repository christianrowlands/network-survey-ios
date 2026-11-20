import Destinations
import Foundation
import NSMessaging

/// Streams the watchlist over MQTT during a survey, the way the Network
/// Survey Android app does:
///
/// - `watchlist_entry_message`: the whole list (a SNAPSHOT) each time the
///   broker connection is made or made again, and whenever the list changes.
///   Each carries a device-wide increasing `messageSequence` (started from the
///   clock, then +1), so a server keeps the list with the highest one. A device
///   that never had an entry sends nothing; once one was sent, an empty list is
///   sent too, so clearing the list reaches the server.
/// - `watchlist_match_message`: each sighting (see `WatchlistMonitor`).
///
/// Both only while `watchlist_stream_enabled` is on (the default). Messages go
/// out one at a time in order, so a snapshot's sequence always matches the
/// order its list was read in.
enum WatchlistStreaming {
    enum Request: Sendable {
        case snapshot
        case match(WatchlistSighting)
    }

    /// Starts streaming to the sinks that take watchlist messages; returns the
    /// tasks to cancel when the session ends (none when no sink streams).
    static func start(
        sinks: [any SurveyRecordSink], store: SurveyStore, settings: SettingsStore, monitor: WatchlistMonitor?,
        session: SessionContext, now: @escaping @Sendable () -> Date
    ) async -> [Task<Void, Never>] {
        var targets: [any SurveyRecordSink] = []
        for sink in sinks where await sink.streamsWatchlist { targets.append(sink) }
        guard !targets.isEmpty else { return [] }
        let (requests, request) = AsyncStream.makeStream(of: Request.self)
        var tasks: [Task<Void, Never>] = []
        tasks.append(Task { [targets] in
            var matchNumber: Int32 = 0
            for await item in requests where settings[Settings.watchlistStreamMQTT] {
                let message: WatchlistMessage
                switch item {
                case .snapshot:
                    guard let entries = try? await store.read(WatchlistQueries.entries),
                          let update = snapshot(entries, settings: settings, session: session, at: now())
                    else { continue }
                    message = .entries(update)
                case .match(let sighting):
                    matchNumber += 1
                    message = .match(match(sighting, recordNumber: matchNumber, session: session))
                }
                for sink in targets { await sink.acceptWatchlist(message) }
            }
        })
        for sink in targets {
            await sink.onWatchlistConnected { request.yield(.snapshot) }
        }
        let entryChanges = store.observe { try WatchlistEntry.fetchAll($0) }
        tasks.append(Task {
            var first = true
            do {
                for try await _ in entryChanges {
                    // The first value is the list as it is; the connection sends that.
                    if first { first = false } else { request.yield(.snapshot) }
                }
            } catch {}
        })
        let settingChanges = settings.changes()
        tasks.append(Task {
            for await name in settingChanges where name == Settings.watchlistStreamMQTT.name {
                if settings[Settings.watchlistStreamMQTT] { request.yield(.snapshot) }
            }
        })
        if let sightings = monitor?.sightings() {
            tasks.append(Task {
                for await sighting in sightings { request.yield(.match(sighting)) }
            })
        }
        return tasks
    }

    /// The SNAPSHOT for `entries`, minting the next sequence; nil for a device
    /// that never sent one and has nothing to send.
    static func snapshot(
        _ entries: [WatchlistEntry], settings: SettingsStore, session: SessionContext, at time: Date
    ) -> WatchlistEntryUpdate? {
        let last = settings[Settings.watchlistMessageSequence]
        if entries.isEmpty && last == 0 { return nil }
        let sequence = last == 0 ? Int((time.timeIntervalSince1970 * 1000).rounded(.down)) : last + 1
        settings[Settings.watchlistMessageSequence] = sequence
        var data = WatchlistEntryUpdateData()
        data.deviceSerialNumber = session.deviceSerialNumber
        data.deviceTime = DeviceTime.string(time, timeZone: session.timeZone)
        data.missionId = session.missionId
        data.messageSequence = UInt64(sequence)
        data.changeType = .snapshot
        data.entries = entries.map { message($0, timeZone: session.timeZone) }
        return WatchlistEntryUpdate(data: data)
    }

    static func message(_ entry: WatchlistEntry, timeZone: TimeZone) -> WatchlistEntryMessage {
        var message = WatchlistEntryMessage()
        message.entryUuid = entry.uuid
        message.label = entry.label
        message.ssid = entry.ssid
        message.bssid = entry.bssid
        message.matchType = matchType(entry)
        message.enabled = entry.enabled
        message.cooldownSeconds = Int32(clamping: entry.cooldownSeconds)
        message.createdAt = DeviceTime.string(entry.createdAt, timeZone: timeZone)
        message.updatedAt = DeviceTime.string(entry.updatedAt, timeZone: timeZone)
        return message
    }

    static func match(_ sighting: WatchlistSighting, recordNumber: Int32, session: SessionContext) -> WatchlistMatch {
        let hit = sighting.hit
        var data = WatchlistMatchData()
        data.apply(RecordContext(
            deviceSerialNumber: session.deviceSerialNumber, missionId: hit.missionId, recordNumber: recordNumber,
            deviceTime: hit.timestamp, location: sighting.location?.fix, timeZone: session.timeZone
        ))
        data.entryUuid = sighting.entry.uuid
        data.label = hit.label
        data.matchType = matchType(sighting.entry)
        data.matchedField = hit.matchedField == .ssid ? .ssid : .bssid
        data.ssid = hit.ssid
        data.bssid = hit.bssid
        data.signalStrength = hit.rssi.map(Float.init)
        return WatchlistMatch(data: data)
    }

    private static func matchType(_ entry: WatchlistEntry) -> WatchlistMatchType {
        entry.matchType == WatchlistEntry.matchTypeExact ? .exact : .unknown
    }
}
