import BoardKit
import BoardProtocol
import Destinations
import Foundation
import Observation

/// One board as the survey screen shows it.
public struct BoardStatusItem: Sendable, Equatable, Identifiable {
    public var id: BoardID
    public var shortID: String
    public var isConnected: Bool
    /// Hello and SetTime done: the board can be surveyed with.
    public var isReady: Bool
    public var firmwareVersion: String?
    public var role: NSBRole?
    public var currentChannel: Int?
    public var recordsPerSecond: Int
    public var batteryMillivolts: Int?
    public var ringFillPercent: Int
    /// Records the board dropped plus notifications lost on the link.
    public var drops: Int
    public var recordCount: Int
}

public struct DestinationItem: Sendable, Equatable, Identifiable {
    public var name: String
    /// Status, counts, queue depth and files.
    public var snapshot: DestinationSnapshot
    public var id: String { name }
    public var status: DestinationStatus { snapshot.status }
}

/// The survey state for SwiftUI: session state, counters, boards and
/// destinations, refreshed about once a second while a survey runs.
@MainActor
@Observable
public final class SurveyModel {
    public private(set) var state = SessionState.idle
    public private(set) var session: SessionRow?
    public private(set) var lastError: SessionError?
    public private(set) var stopReason: StopReason?
    /// Authorization when the session started; not When In Use means no phone location.
    public private(set) var locationAuthorization: LocationAuthorization?
    public private(set) var issue: String?
    public private(set) var counters = PipelineCounters()
    /// Unique APs, clients, probe pairs and BLE devices this session.
    public private(set) var uniqueCounts = SurveyCounts()
    public private(set) var boards: [BoardStatusItem] = []
    public private(set) var destinations: [DestinationItem] = []
    public private(set) var location: LocationSample?

    @ObservationIgnored public let controller: SurveySessionController
    @ObservationIgnored public let store: SurveyStore
    @ObservationIgnored private let boardManager: BoardManager?
    @ObservationIgnored private let refreshInterval: Duration
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    public init(
        controller: SurveySessionController, store: SurveyStore, boardManager: BoardManager?,
        refreshInterval: Duration = .seconds(1)
    ) {
        self.controller = controller
        self.store = store
        self.boardManager = boardManager
        self.refreshInterval = refreshInterval
        let updates = controller.updates()
        tasks.append(Task { [weak self] in
            for await snapshot in updates {
                self?.apply(snapshot)
            }
        })
        tasks.append(Task { [weak self, refreshInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: refreshInterval)
                guard let self else { return }
                await self.refresh()
            }
        })
    }

    /// Protocols and destinations cannot change while this is true.
    public var isLocked: Bool { state != .idle }
    public var isRunning: Bool { state == .running }
    public var missionId: String? { session?.missionId }
    public var startedAt: Date? { session?.startedAt }
    public var canStart: Bool { state == .idle && boards.contains(where: \.isReady) }

    public func start() async {
        _ = try? await controller.start()
        await refresh()
    }

    public func stop() async {
        await controller.stop()
        boards = boardItems()
        // The final totals, after the last flush (the state may already be idle).
        await refreshTotals()
    }

    public func refresh() async {
        boards = boardItems()
        guard state == .running || state == .stopping else { return }
        await refreshTotals()
    }

    private func refreshTotals() async {
        guard let session else { return }
        if let counters = await controller.counters { self.counters = counters }
        location = await controller.currentLocation
        let id = session.id
        if let counts = try? await store.read({ try StoreQueries.counts($0, sessionID: id) }) {
            uniqueCounts = counts
        }
        destinations = await controller.destinationSnapshots()
            .map { DestinationItem(name: $0.key, snapshot: $0.value) }
            .sorted { $0.name < $1.name }
    }

    private func apply(_ snapshot: SessionSnapshot) {
        let started = snapshot.session?.id != session?.id && snapshot.state != .idle
        state = snapshot.state
        session = snapshot.session
        lastError = snapshot.lastError
        stopReason = snapshot.stopReason
        locationAuthorization = snapshot.locationAuthorization
        issue = snapshot.issue
        if started {
            counters = PipelineCounters()
            uniqueCounts = SurveyCounts()
        }
    }

    private func boardItems() -> [BoardStatusItem] {
        guard let boardManager else { return [] }
        return boardManager.boards.map { id, board in
            let status = board.status
            return BoardStatusItem(
                id: id,
                shortID: board.info?.shortID ?? String(id.description.suffix(4)),
                isConnected: board.connection.isConnected,
                isReady: board.isReady,
                firmwareVersion: board.info?.firmwareVersion,
                role: status?.role,
                currentChannel: status.map { Int($0.currentChannel) }.flatMap { $0 > 0 ? $0 : nil },
                recordsPerSecond: Int(status?.recordsPerSec ?? 0),
                batteryMillivolts: status.flatMap { $0.hasBatteryMv ? Int($0.batteryMv) : nil },
                ringFillPercent: Int(status?.ringFillPercent ?? 0),
                drops: Int(status?.droppedRecords ?? 0) + board.missedNotifications,
                recordCount: board.recordCount
            )
        }
        .sorted { $0.shortID < $1.shortID }
    }
}
