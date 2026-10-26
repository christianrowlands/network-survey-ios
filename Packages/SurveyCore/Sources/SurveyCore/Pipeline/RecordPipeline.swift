import BoardKit
import BoardProtocol
import Foundation

/// The per-session record path: board record, wall time, location, privacy
/// filter, database, record number, destinations.
///
/// Records are buffered and written in batches (`maxPending`, or whenever the
/// session calls `flush()`, about once a second) to keep background wakes
/// short. Flushes run strictly in order, so destinations see records in
/// record number order. When storage or destinations fall behind
/// (`maxInFlight` flushes queued), ingestion waits and raw frames are shed.
///
/// Privacy zones fail closed: a record is inside when its distance to the
/// center minus the fix's accuracy is within the radius. Without a current
/// fix, the last known fix up to `zoneFallbackAge` old is used; with none at
/// all the record is kept (it cannot be placed).
public actor RecordPipeline {
    public let session: SessionContext
    private let store: SurveyStore
    private let sinks: [any SurveyRecordSink]
    private var privacy: PrivacyFilter
    private let policy: LocationSourcePolicy
    private let battery: any BatteryProvider
    private let maxPending: Int
    private let maxInFlight = 4
    private let now: @Sendable () -> Date
    /// How old a fix may be and still place a record for the zone check.
    static let zoneFallbackAge: TimeInterval = 300

    private var clock = BoardClock()
    private var phoneFixes = LocationHistory()
    private var boardFixes = LocationHistory()
    private var numbers: RecordNumbers
    private var pending: [StoredRecord] = []
    private var pendingTrack: [LocationSample] = []
    private var pendingFiltered = 0
    private var pendingOutputs: [SurveyOutput] = []
    private var pendingRaw: [RawFrameOutput] = []
    private var flushTail: Task<Void, Never>?
    private var inFlight = 0
    private var thinner = ObservationThinner()
    public private(set) var counters = PipelineCounters()

    public init(
        session: SessionContext, store: SurveyStore, sinks: [any SurveyRecordSink], privacy: PrivacyFilter,
        policy: LocationSourcePolicy, battery: any BatteryProvider = UnknownBattery(), maxPending: Int = 200,
        numbers: RecordNumbers = RecordNumbers(), now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.store = store
        self.sinks = sinks
        self.privacy = privacy
        self.policy = policy
        self.battery = battery
        self.maxPending = maxPending
        self.numbers = numbers
        self.now = now
    }

    // MARK: - Input

    /// One record as BoardKit delivers it. `boardTimeMs` is epoch time when the
    /// board clock was synced, else nil and the record's own uptime is mapped.
    public func ingest(_ envelope: BoardRecordEnvelope) async {
        let synced = envelope.boardTimeMs != nil
        add(envelope.record, synced: synced, board: envelope.boardID, receivedAt: envelope.receivedAt)
        if pending.count >= maxPending { await flush(wait: inFlight >= maxInFlight) }
    }

    /// A whole RecordBatch (tests and tools that read the transport directly).
    public func ingest(_ received: ReceivedRecordBatch, from board: BoardID) async {
        counters.lostNotifications += received.missedNotifications
        for record in received.batch.records {
            add(record, synced: received.batch.timeSynced, board: board, receivedAt: received.receivedAt)
        }
        if pending.count >= maxPending { await flush(wait: inFlight >= maxInFlight) }
    }

    private func add(_ record: NSBRecord, synced: Bool, board: BoardID, receivedAt: Date) {
        guard let kind = record.kind else { return }
        let time = clock.wallTime(boardTimeMs: kind.boardTimeMs, synced: synced, board: board, receivedAt: receivedAt)
        if case .gps(let fix) = kind {
            if let sample = LocationSample(fix, wallTime: time) { addFix(sample) }
            return
        }
        guard let type = kind.messageType, isPlanned(type) else { return }
        counters.received[type, default: 0] += 1
        counters.perBoard[board.description, default: 0] += 1
        let location = location(at: time)
        guard privacy.allows(kind, fix: location ?? lastKnownFix(at: time)) else {
            pendingFiltered += 1
            counters.filtered += 1
            return
        }
        let keep = thinner.keep(kind, board: board.description, time: time, point: location?.point)
        pending.append(StoredRecord(boardID: board.description, time: time, location: location, kind: kind, keepObservation: keep))
        counters.lastRecordAt = max(counters.lastRecordAt ?? time, time)
    }

    /// Applies a changed privacy zone or ignore list from now on. Records
    /// already stored stay.
    public func setPrivacy(_ filter: PrivacyFilter) {
        privacy = filter
    }

    public func ingestStatus(_ status: NSBBoardStatus, from board: BoardID, receivedAt: Date) {
        clock.noteStatus(status, from: board, receivedAt: receivedAt)
    }

    /// A dropped board may reboot; its old uptime offset no longer applies.
    public func boardGapStarted(_ board: BoardID) {
        clock.forget(board)
    }

    /// Phone fixes older than the policy's `maxAge` (the cached fix Core
    /// Location often delivers first) are ignored.
    public func ingestPhoneLocation(_ sample: LocationSample) {
        guard sample.timestamp >= now().addingTimeInterval(-policy.maxAge) else { return }
        addFix(sample)
    }

    public func ingestRaw(_ envelope: BoardRawFrameEnvelope) {
        ingestRaw(envelope.frame, from: envelope.boardID, receivedAt: envelope.receivedAt)
    }

    public func ingestRaw(_ frame: NSBRawFrame, from board: BoardID, receivedAt: Date) {
        guard session.plan.rawFrames else { return }
        guard inFlight < maxInFlight else {
            counters.rawFramesShed += 1
            return
        }
        let time = clock.wallTime(
            boardTimeMs: frame.boardTimeUs / 1000, synced: frame.timeSynced, board: board, receivedAt: receivedAt
        )
        guard privacy.allowsRawFrame(frame.data, fix: location(at: time) ?? lastKnownFix(at: time)) else {
            counters.filtered += 1
            return
        }
        counters.rawFrames += 1
        pendingRaw.append(RawFrameOutput(boardID: board.description, frame: frame, time: time))
    }

    /// Queues a DeviceStatus record with the current location and battery.
    /// Inside a privacy zone it goes out without a location.
    public func emitDeviceStatus(connectedBoards: Int, at now: Date = Date()) async {
        let level = await battery.batteryLevel()
        var location = location(at: now)
        if privacy.isInsideZone(fix: location ?? lastKnownFix(at: now)) { location = nil }
        var boardGPS = boardFixes.nearest(to: now).flatMap { abs($0.timestamp.timeIntervalSince(now)) <= policy.maxAge ? $0 : nil }
        if boardGPS == location || privacy.isInsideZone(fix: boardGPS) || location == nil { boardGPS = nil }
        let info = DeviceStatusInfo(
            batteryLevelPercent: level.map { Int(($0 * 100).rounded()) }, connectedBoards: connectedBoards,
            boardGPS: boardGPS, deviceModel: session.app.deviceModel, appVersion: session.app.appVersion
        )
        pendingOutputs.append(output(.deviceStatus, payload: .deviceStatus(info), time: now, location: location, board: nil))
        await flush(wait: false)
    }

    /// The position records observed at `time` are stamped with.
    public func location(at time: Date) -> LocationSample? {
        policy.choose(phone: phoneFixes.nearest(to: time), board: boardFixes.nearest(to: time), at: time)
    }

    public var latestLocation: LocationSample? {
        policy.choose(phone: phoneFixes.latest, board: boardFixes.latest, at: now())
    }

    /// The fix nearest in time from either source, if within `zoneFallbackAge`.
    private func lastKnownFix(at time: Date) -> LocationSample? {
        [phoneFixes.nearest(to: time), boardFixes.nearest(to: time)]
            .compactMap { $0 }
            .filter { abs($0.timestamp.timeIntervalSince(time)) <= Self.zoneFallbackAge }
            .min { abs($0.timestamp.timeIntervalSince(time)) < abs($1.timestamp.timeIntervalSince(time)) }
    }

    // MARK: - Output

    /// Writes buffered records and hands them to the destinations. With
    /// `wait`, returns when this and every earlier flush has finished.
    public func flush(wait: Bool = true) async {
        let records = pending, track = pendingTrack, filtered = pendingFiltered
        var outputs = pendingOutputs
        let raw = pendingRaw
        pending = []
        pendingTrack = []
        pendingFiltered = 0
        pendingOutputs = []
        pendingRaw = []
        guard !records.isEmpty || !track.isEmpty || filtered > 0 || !outputs.isEmpty || !raw.isEmpty else {
            if wait { await flushTail?.value }
            return
        }
        // Numbers are assigned here, in arrival order, after the privacy filter,
        // and saved with the records so a resumed session continues them.
        outputs = records.map(output(for:)) + outputs
        for item in outputs { counters.delivered[item.type, default: 0] += 1 }
        let numbers = self.numbers

        let previous = flushTail
        inFlight += 1
        let task = Task { [store, sinks, session] in
            await previous?.value
            do {
                try await store.write(
                    sessionID: session.sessionID, records: records, trackPoints: track, filteredCount: filtered,
                    recordNumbers: numbers
                )
            } catch {
                self.noteStoreError()
            }
            for sink in sinks {
                if !outputs.isEmpty { await sink.accept(outputs) }
                if !raw.isEmpty { await sink.acceptRaw(raw) }
            }
            self.flushFinished()
        }
        flushTail = task
        if wait { await task.value }
    }

    private func flushFinished() {
        inFlight -= 1
    }

    private func noteStoreError() {
        counters.storeErrors += 1
    }

    private func output(for record: StoredRecord) -> SurveyOutput {
        let payload: SurveyOutput.Payload
        let type: MessageType
        switch record.kind {
        case .ap(let ap): (type, payload) = (.wifiBeacon, .accessPoint(ap))
        case .client(let client): (type, payload) = (.wifiStation, .client(client))
        case .probe(let probe): (type, payload) = (.wifiProbeRequest, .probe(probe))
        case .ble(let ble): (type, payload) = (.bluetooth, .ble(ble))
        case .gps: preconditionFailure("GPS fixes are never stored as records")
        }
        return output(type, payload: payload, time: record.time, location: record.location, board: record.boardID)
    }

    private func output(
        _ type: MessageType, payload: SurveyOutput.Payload, time: Date, location: LocationSample?, board: String?
    ) -> SurveyOutput {
        let context = OutputContext(
            deviceSerialNumber: session.deviceSerialNumber, deviceName: session.deviceName,
            missionId: session.missionId, recordNumber: numbers.take(type), deviceTime: time,
            location: location, boardID: board
        )
        return SurveyOutput(type: type, payload: payload, context: context)
    }

    private func addFix(_ sample: LocationSample) {
        switch sample.source {
        case .phone: phoneFixes.append(sample)
        case .boardGPS: boardFixes.append(sample)
        }
        // The track follows whichever source the policy picks at that moment.
        let other = sample.source == .phone ? boardFixes.nearest(to: sample.timestamp) : phoneFixes.nearest(to: sample.timestamp)
        let chosen = sample.source == .phone
            ? policy.choose(phone: sample, board: other, at: sample.timestamp)
            : policy.choose(phone: other, board: sample, at: sample.timestamp)
        if chosen == sample, !privacy.isInsideZone(fix: sample) {
            pendingTrack.append(sample)
        }
    }

    private func isPlanned(_ type: MessageType) -> Bool {
        switch type {
        case .wifiBeacon: session.plan.wifiAP
        case .wifiStation, .wifiProbeRequest: session.plan.wifiClient
        case .bluetooth: session.plan.ble
        case .deviceStatus: true
        }
    }
}

extension NSBRecord.OneOf_Kind {
    var messageType: MessageType? {
        switch self {
        case .ap: .wifiBeacon
        case .client: .wifiStation
        case .probe: .wifiProbeRequest
        case .ble: .bluetooth
        case .gps: nil
        }
    }

    var boardTimeMs: UInt64 {
        switch self {
        case .ap(let r): r.boardTimeMs
        case .client(let r): r.boardTimeMs
        case .probe(let r): r.boardTimeMs
        case .ble(let r): r.boardTimeMs
        case .gps(let r): r.boardTimeMs
        }
    }
}
