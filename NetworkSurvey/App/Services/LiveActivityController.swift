@preconcurrency import ActivityKit
import Foundation
import OSLog

/// When to send a Live Activity update. The elapsed time ticks on its own, so
/// counts go out at most every 10 s; a board connecting, dropping or reporting
/// a problem goes out after 2 s; and the content is re-sent at least every
/// 60 s so its stale date keeps moving while the survey is quiet.
struct LiveActivityThrottle {
    static let minimumInterval: TimeInterval = 10
    static let urgentInterval: TimeInterval = 2
    static let refreshInterval: TimeInterval = 60

    private(set) var lastState: SurveyActivityAttributes.ContentState?
    private var lastSent = Date.distantPast

    mutating func reset(sent state: SurveyActivityAttributes.ContentState?, at now: Date) {
        lastState = state
        lastSent = state == nil ? .distantPast : now
    }

    mutating func shouldSend(_ state: SurveyActivityAttributes.ContentState, now: Date) -> Bool {
        let elapsed = now.timeIntervalSince(lastSent)
        let urgent = state.problem != lastState?.problem || state.boardsConnected != lastState?.boardsConnected
        let changed = state != lastState
        let send = elapsed >= Self.refreshInterval
            || (changed && elapsed >= Self.minimumInterval)
            || (changed && urgent && elapsed >= Self.urgentInterval)
        if send { reset(sent: state, at: now) }
        return send
    }
}

/// Starts, updates and ends the survey's Live Activity. Calls to ActivityKit
/// run one after another, so an update can never land after the end.
@MainActor
final class LiveActivityController {
    private static let log = Logger(subsystem: "app.networksurvey.ios", category: "liveActivity")
    /// Without an update for this long the system may mark the activity stale.
    static let staleAfter: TimeInterval = 120

    private var activity: Activity<SurveyActivityAttributes>?
    private var throttle = LiveActivityThrottle()
    /// The mission a start is running or done for, so a start is not repeated every second.
    private var attemptedMission: String?
    private var queue: Task<Void, Never>?

    var isRunning: Bool { activity != nil }

    /// Ends activities left behind by an earlier launch (other than `keeping`).
    func endStale(keeping missionID: String? = nil) async {
        for stale in Activity<SurveyActivityAttributes>.activities where stale.attributes.missionID != missionID {
            await stale.end(nil, dismissalPolicy: .immediate)
        }
        activity = Activity<SurveyActivityAttributes>.activities.first { $0.attributes.missionID == missionID }
        if activity != nil { attemptedMission = missionID }
    }

    /// Starts the activity for a mission once. A refused start (for example in
    /// the background) can be tried again later.
    func start(missionID: String, startedAt: Date, state: SurveyActivityAttributes.ContentState) {
        guard activity == nil, attemptedMission != missionID, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = SurveyActivityAttributes(missionID: missionID, startedAt: startedAt)
        do {
            activity = try Activity.request(attributes: attributes, content: content(state), pushType: nil)
            attemptedMission = missionID
            throttle.reset(sent: state, at: Date())
        } catch {
            Self.log.error("Live Activity not started: \(error.localizedDescription, privacy: .public)")
        }
    }

    func update(_ state: SurveyActivityAttributes.ContentState, now: Date = Date()) {
        guard let activity, throttle.shouldSend(state, now: now) else { return }
        let content = content(state)
        enqueue { await activity.update(content) }
    }

    func end(final state: SurveyActivityAttributes.ContentState?) {
        guard let activity else { return }
        self.activity = nil
        attemptedMission = nil
        throttle.reset(sent: nil, at: Date())
        var final = state ?? activity.content.state
        final.stoppedAt = Date()
        let content = ActivityContent(state: final, staleDate: nil)
        enqueue { await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(15 * 60))) }
    }

    private func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        let previous = queue
        queue = Task {
            await previous?.value
            await operation()
        }
    }

    private func content(_ state: SurveyActivityAttributes.ContentState) -> ActivityContent<SurveyActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter))
    }
}
