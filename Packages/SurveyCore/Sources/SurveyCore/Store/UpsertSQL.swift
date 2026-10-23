/// Insert-or-merge statements for the entity tables.
///
/// In an UPSERT's DO UPDATE clause, bare column names are the stored row and
/// `excluded.*` is the new observation; every SET sees the stored values.
enum UpsertSQL {
    private static let entityColumns =
        "firstSeen, lastSeen, observationCount, frameCount, rssiLast, rssiMax, lastBoardId, bestRssi, bestLatitude, bestLongitude"

    private static let strongerHere =
        "excluded.bestRssi IS NOT NULL AND (bestRssi IS NULL OR excluded.bestRssi > bestRssi)"

    private static let entityUpdates = """
        firstSeen = MIN(firstSeen, excluded.firstSeen),
        lastSeen = MAX(lastSeen, excluded.lastSeen),
        observationCount = observationCount + 1,
        frameCount = frameCount + excluded.frameCount,
        rssiLast = CASE WHEN excluded.lastSeen >= lastSeen THEN excluded.rssiLast ELSE rssiLast END,
        rssiMax = MAX(rssiMax, excluded.rssiMax),
        lastBoardId = excluded.lastBoardId,
        bestLatitude = CASE WHEN \(strongerHere) THEN excluded.bestLatitude ELSE bestLatitude END,
        bestLongitude = CASE WHEN \(strongerHere) THEN excluded.bestLongitude ELSE bestLongitude END,
        bestRssi = CASE WHEN \(strongerHere) THEN excluded.bestRssi ELSE bestRssi END
        """

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    static let accessPoint = """
        INSERT INTO accessPoint (sessionId, bssid, ssid, ssidHidden, band, channel, frequencyMhz, security,
            groupCipher, pairwiseCiphers, akmSuites, channelWidth, phyFlags, wps, passpoint, beaconIntervalTu,
            stationCount, channelUtilization, randomized, \(entityColumns))
        VALUES (\(placeholders(29)))
        ON CONFLICT(sessionId, bssid) DO UPDATE SET
            ssid = COALESCE(excluded.ssid, ssid),
            ssidHidden = ssidHidden AND excluded.ssidHidden,
            band = excluded.band,
            channel = excluded.channel,
            frequencyMhz = excluded.frequencyMhz,
            security = CASE WHEN excluded.security = 0 THEN security ELSE excluded.security END,
            groupCipher = CASE WHEN excluded.groupCipher = 0 THEN groupCipher ELSE excluded.groupCipher END,
            pairwiseCiphers = CASE WHEN excluded.pairwiseCiphers = '' THEN pairwiseCiphers ELSE excluded.pairwiseCiphers END,
            akmSuites = CASE WHEN excluded.akmSuites = '' THEN akmSuites ELSE excluded.akmSuites END,
            channelWidth = CASE WHEN excluded.channelWidth = 0 THEN channelWidth ELSE excluded.channelWidth END,
            phyFlags = phyFlags | excluded.phyFlags,
            wps = wps OR excluded.wps,
            passpoint = passpoint OR excluded.passpoint,
            beaconIntervalTu = COALESCE(excluded.beaconIntervalTu, beaconIntervalTu),
            stationCount = COALESCE(excluded.stationCount, stationCount),
            channelUtilization = COALESCE(excluded.channelUtilization, channelUtilization),
            \(entityUpdates)
        """

    static let client = """
        INSERT INTO client (sessionId, mac, randomized, associatedBssid, sourceFlags, band, channel, \(entityColumns))
        VALUES (\(placeholders(17)))
        ON CONFLICT(sessionId, mac) DO UPDATE SET
            associatedBssid = COALESCE(excluded.associatedBssid, associatedBssid),
            sourceFlags = sourceFlags | excluded.sourceFlags,
            band = excluded.band,
            channel = excluded.channel,
            \(entityUpdates)
        """

    static let probe = """
        INSERT INTO probe (sessionId, clientMac, ssid, randomized, band, channel, \(entityColumns))
        VALUES (\(placeholders(16)))
        ON CONFLICT(sessionId, clientMac, ssid) DO UPDATE SET
            band = excluded.band,
            channel = excluded.channel,
            \(entityUpdates)
        """

    static let bleDevice = """
        INSERT INTO bleDevice (sessionId, address, addressType, randomized, name, companyId, txPower, advType,
            advData, \(entityColumns))
        VALUES (\(placeholders(19)))
        ON CONFLICT(sessionId, address) DO UPDATE SET
            name = COALESCE(excluded.name, name),
            companyId = COALESCE(excluded.companyId, companyId),
            txPower = COALESCE(excluded.txPower, txPower),
            advType = excluded.advType,
            advData = excluded.advData,
            \(entityUpdates)
        """

    static let observation = """
        INSERT INTO observation (sessionId, kind, identity, boardId, time, rssi, rssiMax, channel, frequencyMhz,
            band, ssid, bssid, latitude, longitude, accuracy)
        VALUES (\(placeholders(15)))
        """
}
