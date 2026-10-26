import Foundation
import SurveyCore

/// One Scout's readings for the signal chart, with a smoothed line through them.
struct ScoutSeries: Identifiable {
    /// The `boardId` the readings were stored with.
    var boardId: String
    /// Position in the Scout palette, fixed by `ScoutSeries.make`.
    var slot: Int
    var readings: [RSSIPoint]
    var line: [SmoothedPoint]

    var id: String { boardId }
    /// The smoothed value at the latest reading.
    var latest: SmoothedPoint? { line.last }

    /// Readings within `average` seconds are averaged into each point of the line.
    static let average: TimeInterval = 5
    /// A silence longer than this breaks the line. Thinning stores a steady
    /// signal only every 10 seconds, so shorter gaps are not silence.
    static let gap: TimeInterval = 25

    struct SmoothedPoint: Identifiable {
        var time: Date
        var rssi: Double
        /// Increases after each gap, so the line does not bridge silence.
        var segment: Int
        var id: Date { time }
    }

    /// Splits `points` by Scout. Scouts in `order` (the survey's boards) keep
    /// their place in the palette; any others follow by ID.
    static func make(_ points: [RSSIPoint], order: [String]) -> [ScoutSeries] {
        let byBoard = Dictionary(grouping: points, by: \.boardId)
        let known = order.filter { byBoard[$0] != nil }
        let others = byBoard.keys.filter { !order.contains($0) }.sorted()
        return (known + others).enumerated().map { slot, boardId in
            let readings = byBoard[boardId] ?? []
            return ScoutSeries(boardId: boardId, slot: slot, readings: readings, line: smoothed(readings))
        }
    }

    /// The line has at most one point per `step` seconds of clock time.
    static let step: TimeInterval = 2

    /// A trailing average: the last reading in each `step` slot becomes the
    /// mean of the readings in the `average` seconds up to it. Slots follow
    /// the clock, so earlier points never move as new readings arrive, and
    /// the last point is the current smoothed value.
    static func smoothed(_ readings: [RSSIPoint]) -> [SmoothedPoint] {
        var result: [SmoothedPoint] = []
        var start = 0
        var sum = 0
        var segment = 0
        for (index, reading) in readings.enumerated() {
            if index > 0, reading.time.timeIntervalSince(readings[index - 1].time) > gap {
                segment += 1
                start = index
                sum = 0
            }
            sum += reading.rssi
            while reading.time.timeIntervalSince(readings[start].time) > average {
                sum -= readings[start].rssi
                start += 1
            }
            let next = index + 1 < readings.count ? readings[index + 1].time : nil
            guard next.map({ slot($0) != slot(reading.time) }) ?? true else { continue }
            result.append(SmoothedPoint(time: reading.time, rssi: Double(sum) / Double(index - start + 1), segment: segment))
        }
        return result
    }

    private static func slot(_ time: Date) -> Int {
        Int((time.timeIntervalSinceReferenceDate / step).rounded(.down))
    }
}
