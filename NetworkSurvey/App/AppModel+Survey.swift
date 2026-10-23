import BoardKit
import Destinations
import Foundation
import SurveyCore
import UIKit

extension AppModel {
    // MARK: - Start and stop

    func startSurvey() async {
        notice = nil
        guard storageProblem == nil else {
            notice = storageProblem
            return
        }
        // A new survey ends one a previous launch left open, so it does not linger
        // as "recording" and cannot be resumed later by mistake.
        if interruptedSession != nil { await endInterrupted() }
        // Real boards need the phone's location (unless the simulated walk stands
        // in for it); ask now if the app never asked.
        let readyReal = boardManager.readyBoards.contains { !isDemo($0) }
        if readyReal && !options.simulatedWalk && access.location == .notDetermined {
            await access.perform(.allow)
        }
        await survey.start()
        // The survey model hears about the new state a moment later; ask the controller.
        let snapshot = await controller.snapshot
        if snapshot.state == .running, let row = snapshot.session {
            startLiveActivity(missionID: row.missionId, startedAt: row.startedAt)
        } else if let error = snapshot.lastError {
            notice = Self.message(for: error)
        }
        updateIdleTimer()
    }

    func stopSurvey() async {
        isStoppingSurvey = true
        defer { isStoppingSurvey = false }
        await survey.stop()
        // After Stop, so the Live Activity ends with the totals of the final flush.
        liveActivity.end(final: activityState())
        updateIdleTimer()
        nsAnalyticsState = await uploader.state()
    }

    static func message(for error: SessionError) -> String {
        switch error {
        case .notIdle: "A survey is already starting or running."
        case .noBoardConnected: "Connect a board to start a survey."
        case .nothingToSurvey: "Choose at least one thing to survey."
        case .boardStartFailed(let reason): "The board did not start: \(reason)"
        }
    }

    // MARK: - Interrupted session

    /// A session with no stop time was cut off (the app was terminated). After a
    /// Bluetooth restoration relaunch it resumes on its own (SurveyCore starts the
    /// boards as they come back); otherwise the Survey screen offers Resume or End.
    func reconcileInterruptedSession(autoResume: Bool) async {
        guard let row = try? await controller.unfinishedSession() else {
            await liveActivity.endStale()
            return
        }
        await liveActivity.endStale(keeping: row.missionId)
        interruptedSession = row
        if autoResume { await resumeInterrupted() }
    }

    func resumeInterrupted() async {
        guard let row = interruptedSession, !isResuming else { return }
        isResuming = true
        defer { isResuming = false }
        do {
            try await controller.resume(row)
            interruptedSession = nil
            notice = nil
            await survey.refresh()
            startLiveActivity(missionID: row.missionId, startedAt: row.startedAt)
        } catch let error as SessionError {
            notice = Self.message(for: error)
        } catch {
            notice = "The survey could not resume: \(error.localizedDescription)"
        }
    }

    func endInterrupted() async {
        guard let row = interruptedSession else { return }
        try? await controller.closeUnfinished(row)
        interruptedSession = nil
        liveActivity.end(final: nil)
    }

    // MARK: - NS Analytics

    /// "Upload now": lifts a quota pause and uploads everything queued.
    func uploadNow() async {
        guard !isUploading else { return }
        isUploading = true
        defer { isUploading = false }
        await uploader.resume()
        let outcome = await uploader.uploadPending(ignoringPause: true)
        nsAnalyticsState = await uploader.state()
        notice = Self.message(for: outcome)
    }

    static func message(for outcome: NSAnalyticsUploader.Outcome) -> String? {
        switch outcome {
        case .uploaded, .alreadyRunning: nil
        case .notRegistered: "Connect this iPhone to an NS Analytics workspace first."
        case .paused(let until): "Uploads are paused until \(until.formatted(date: .abbreviated, time: .shortened))."
        case .quotaExceeded(let info): info.message.isEmpty ? "The workspace quota is used up." : info.message
        case .registrationInvalid, .deregistered, .invalidToken: "This iPhone was disconnected from its NS Analytics workspace."
        case .viewerCannotUpload: "Your workspace role does not allow uploading data."
        case .failed(_, let reason): "Upload stopped: \(reason)"
        }
    }

    /// The NS Analytics registration link (QR code or universal link).
    func handleOpenURL(_ url: URL) {
        guard url.host() == "networksurvey.app", url.path().hasPrefix("/app/register") else { return }
        pendingRegistrationLink = url
    }

    // MARK: - Live Activity

    /// ActivityKit starts activities only while the app is in the foreground;
    /// a background resume gets its activity when the user next opens the app.
    func startLiveActivity(missionID: String, startedAt: Date) {
        guard UIApplication.shared.applicationState == .active else { return }
        liveActivity.start(missionID: missionID, startedAt: startedAt, state: activityState())
    }

    func syncLiveActivity() {
        if survey.isRunning, let missionId = survey.missionId, let startedAt = survey.startedAt {
            // Covers a survey started or resumed without going through startSurvey.
            startLiveActivity(missionID: missionId, startedAt: startedAt)
            liveActivity.update(activityState())
        } else if survey.state == .idle && liveActivity.isRunning && !isStoppingSurvey {
            liveActivity.end(final: nil)
        }
    }

    func activityState() -> SurveyActivityAttributes.ContentState {
        let boards = boardManager.boards.values.filter { $0.assignment != nil || $0.connection.isConnected }
        let connected = boards.filter { $0.connection.isConnected }
        let batteries = connected.compactMap { $0.status.flatMap(BoardBattery.percent) }
        let delivered = survey.counters.delivered.filter { $0.key != .deviceStatus }.values.reduce(0, +)
        let problem = boards.contains { $0.reconnect != nil || !$0.connection.isConnected || $0.issue != nil }
        let lost = boards.reduce(0) { $0 + $1.counters.droppedRecords + $1.counters.missedNotifications }
        if lost > lostRecords.total { lostRecords = (lost, Date()) } else if lost < lostRecords.total { lostRecords.total = lost }
        return SurveyActivityAttributes.ContentState(
            recordCount: delivered, accessPoints: survey.uniqueCounts.accessPoints, clients: survey.uniqueCounts.clients,
            bluetoothDevices: survey.uniqueCounts.bleDevices, boardsConnected: connected.count, boardsInSurvey: boards.count,
            lowestBatteryPercent: batteries.min(), boardProblem: problem,
            losingRecords: Date().timeIntervalSince(lostRecords.grewAt) < 60
        )
    }
}
