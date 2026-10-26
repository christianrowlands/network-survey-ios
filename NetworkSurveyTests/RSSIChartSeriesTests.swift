import Foundation
import SurveyCore
import Testing
@testable import NetworkSurvey

@Suite("Signal chart series") @MainActor
struct RSSIChartSeriesTests {
    /// On a 2 second slot boundary, so slot arithmetic is exact.
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func reading(_ offset: TimeInterval, _ rssi: Int, board: String = "A") -> RSSIPoint {
        RSSIPoint(time: t0 + offset, rssi: rssi, boardId: board, channel: 1)
    }

    @Test func lineIsTheTrailingAverageOnceEverySlot() {
        let line = ScoutSeries.smoothed([
            reading(0, -60), reading(0.5, -70), reading(1, -80),
            reading(2, -50), reading(3, -60), reading(7.5, -90),
        ])
        // One point per 2 second slot, at its last reading.
        #expect(line.map(\.time) == [t0 + 1, t0 + 3, t0 + 7.5])
        // Each is the mean of the readings in the 5 seconds up to it.
        #expect(line.map(\.rssi) == [-70, -64, -75])
        #expect(Set(line.map(\.segment)) == [0])
    }

    @Test func longSilenceStartsANewSegment() {
        let line = ScoutSeries.smoothed([reading(0, -60), reading(10, -62), reading(40, -80)])
        #expect(line.map(\.segment) == [0, 0, 1])
        // The average does not reach back across the gap.
        #expect(line.last?.rssi == -80)
    }

    @Test func scoutsKeepTheSurveyOrderInThePalette() {
        let points = [reading(0, -60, board: "C"), reading(1, -70, board: "B"), reading(2, -80, board: "X")]
        let scouts = ScoutSeries.make(points, order: ["A", "B", "C"])
        #expect(scouts.map(\.boardId) == ["B", "C", "X"])
        #expect(scouts.map(\.slot) == [0, 1, 2])
        #expect(scouts[0].latest?.rssi == -70)
    }
}
