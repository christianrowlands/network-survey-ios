import ActivityKit
import Foundation

/// The Live Activity shown while a survey runs. Compiled into the app (which
/// starts and updates it) and the widget extension (which draws it).
nonisolated struct SurveyActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        /// Records delivered this session, all types.
        var recordCount: Int
        /// Unique access points, clients and Bluetooth devices this session.
        var accessPoints: Int
        var clients: Int
        var bluetoothDevices: Int
        var boardsConnected: Int
        /// Boards in the survey, connected or not.
        var boardsInSurvey: Int
        /// Lowest battery among connected boards, if any runs on battery.
        var lowestBatteryPercent: Int?
        /// A board dropped and is reconnecting, or needs the user.
        var boardProblem: Bool
        /// A board lost records in the last minute.
        var losingRecords: Bool
        /// Set when the survey stopped; the activity then shows the final counts.
        var stoppedAt: Date?

        init(
            recordCount: Int = 0, accessPoints: Int = 0, clients: Int = 0, bluetoothDevices: Int = 0,
            boardsConnected: Int = 0, boardsInSurvey: Int = 0, lowestBatteryPercent: Int? = nil,
            boardProblem: Bool = false, losingRecords: Bool = false, stoppedAt: Date? = nil
        ) {
            self.recordCount = recordCount
            self.accessPoints = accessPoints
            self.clients = clients
            self.bluetoothDevices = bluetoothDevices
            self.boardsConnected = boardsConnected
            self.boardsInSurvey = boardsInSurvey
            self.lowestBatteryPercent = lowestBatteryPercent
            self.boardProblem = boardProblem
            self.losingRecords = losingRecords
            self.stoppedAt = stoppedAt
        }
    }

    var missionID: String
    var startedAt: Date
}

extension SurveyActivityAttributes.ContentState {
    /// What is wrong, worst first, as a headline; nil when all is well.
    var problem: String? {
        guard stoppedAt == nil else { return nil }
        let missing = boardsInSurvey - boardsConnected
        if missing > 0 { return missing == 1 ? "1 Scout disconnected" : "\(missing) Scouts disconnected" }
        if let battery = lowestBatteryPercent, battery < 15 { return "Scout battery low" }
        if losingRecords { return "Scout losing records" }
        if boardProblem { return "Scout needs attention" }
        return nil
    }
}

/// Elapsed time the way the system timer text shows it: M:SS under an hour,
/// H:MM:SS from an hour on. Used for every elapsed time in the app.
nonisolated enum ElapsedFormat {
    static func string(_ interval: TimeInterval) -> String {
        let seconds = max(Int(interval), 0)
        let (hours, minutes, rest) = (seconds / 3600, seconds % 3600 / 60, seconds % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}
