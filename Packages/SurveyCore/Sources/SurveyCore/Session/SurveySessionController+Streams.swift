import BoardKit
import Foundation

extension SurveySessionController {
    // MARK: - Streams and timers

    func subscribe(_ pipeline: RecordPipeline, sessionID: String) {
        let records = env.boards.records()
        let rawFrames = env.boards.rawFrames()
        let events = env.boards.events()
        let fixes = env.location.updates()
        tasks.append(Task {
            for await envelope in records { await pipeline.ingest(envelope) }
        })
        tasks.append(Task {
            for await envelope in rawFrames { await pipeline.ingestRaw(envelope) }
        })
        tasks.append(Task { [weak self] in
            for await event in events {
                if case .status(let board, let status, let receivedAt) = event {
                    await pipeline.ingestStatus(status, from: board, receivedAt: receivedAt)
                } else {
                    await self?.boardEvent(event, sessionID: sessionID, pipeline: pipeline)
                }
            }
        })
        tasks.append(Task {
            for await fix in fixes { await pipeline.ingestPhoneLocation(fix) }
        })
        // Zones and ignore entries added mid-survey apply right away.
        let settings = env.settings
        let changes = settings.changes()
        tasks.append(Task {
            for await name in changes where name == Settings.privacyZones.name || name == Settings.ignoreList.name {
                await pipeline.setPrivacy(PrivacyFilter(settings: settings))
            }
        })
    }

    func startTimers(_ pipeline: RecordPipeline) {
        let flushInterval = env.flushInterval
        tasks.append(Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: flushInterval)
                // Only Stop waits for the destinations; the timer just queues.
                await pipeline.flush(wait: false)
            }
        })
        let statusInterval = env.deviceStatusInterval ?? .seconds(env.settings[Settings.deviceStatusIntervalSeconds])
        let boards = env.boards
        tasks.append(Task {
            // The first status goes out shortly after Start, as on Android.
            try? await Task.sleep(for: min(.seconds(1), statusInterval))
            while !Task.isCancelled {
                await pipeline.emitDeviceStatus(connectedBoards: await boards.readyBoards().count)
                try? await Task.sleep(for: statusInterval)
            }
        })
        let freeSpace = env.freeSpace, minimum = env.minimumFreeBytes
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                if let free = freeSpace(), free < minimum {
                    // Stop from outside this task: Stop cancels and awaits it.
                    Task { await self?.stop(reason: .lowDiskSpace) }
                    return
                }
                try? await Task.sleep(for: .seconds(30))
            }
        })
    }

    /// After a relaunch the boards are still reconnecting; start the survey on
    /// them once at least one is ready. BoardManager re-plans as more join.
    func startBoardsWhenReady(_ plan: SurveyPlan) {
        let boards = env.boards
        boardStartTask = Task {
            while !Task.isCancelled {
                if !(await boards.readyBoards()).isEmpty, (try? await boards.startSurvey(plan)) != nil { return }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Gap events keep the session and missionId; BoardKit reconnects and
    /// re-plans the boards by itself.
    func boardEvent(_ event: SurveyBoardEvent, sessionID: String, pipeline: RecordPipeline) async {
        guard state == .running || state == .starting else { return }
        let store = env.store
        switch event {
        case .gapStarted(let board, let at):
            await pipeline.boardGapStarted(board)
            guard openGaps[board] == nil else { return }
            if let id = try? await store.openGap(sessionID: sessionID, boardID: board.description, at: at, reason: "linkLost") {
                openGaps[board] = id
            }
        case .gapEnded(let board, let at, let resumed):
            guard let id = openGaps.removeValue(forKey: board) else { return }
            try? await store.closeGap(id, at: at, resumed: resumed)
        case .boardDrops(let board, let records, let at):
            try? await store.recordLoss(
                sessionID: sessionID, boardID: board.description, count: records, reason: "boardDropped", at: at
            )
        case .status:
            break
        }
    }
}
