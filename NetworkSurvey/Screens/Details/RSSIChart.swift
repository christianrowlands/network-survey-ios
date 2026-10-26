import BoardKit
import Charts
import SurveyCore
import SwiftUI

/// Signal over the last two minutes. The headline is the smoothed value from
/// the strongest Scout. Each Scout gets its own colored line through its
/// readings, which stay visible as faint dots behind it.
struct RSSIChart: View {
    let points: [RSSIPoint]

    @Environment(AppModel.self) private var app

    /// How far back the chart looks, in seconds. `StoreQueries.rssiHistory` fetches the same window.
    static let window: TimeInterval = 120
    /// Marker shapes by palette slot, so Scouts differ by more than color.
    static let symbols: [BasicChartSymbolShape] = [.circle, .square, .triangle, .diamond]

    var body: some View {
        if points.isEmpty {
            Text("Signal history appears after a few observations.")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Colors.ink2)
        } else {
            let scouts = ScoutSeries.make(points, order: app.boardsInUse.map(\.description))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(scouts: scouts, now: context.date)
            }
        }
    }

    private func content(scouts: [ScoutSeries], now: Date) -> some View {
        let latestTime = points.map(\.time).max() ?? now
        // A device that went quiet keeps its last two minutes on screen.
        let end = now.timeIntervalSince(latestTime) < Self.window ? max(now, latestTime) : latestTime
        let strongest = scouts.max { ($0.latest?.rssi ?? -.infinity) < ($1.latest?.rssi ?? -.infinity) }
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            readout(strongest: strongest, multiple: scouts.count > 1, latestTime: latestTime, now: now)
            chart(scouts: scouts, end: end)
            if scouts.count > 1 { legend(scouts) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signal over the last two minutes")
        .accessibilityValue(summary(scouts: scouts, strongest: strongest))
    }

    private func chart(scouts: [ScoutSeries], end: Date) -> some View {
        Chart {
            ForEach(scouts) { scout in
                ForEach(Array(scout.readings.enumerated()), id: \.offset) { _, reading in
                    PointMark(x: .value("Seconds", reading.time.timeIntervalSince(end)), y: .value("Signal", reading.rssi))
                        .symbolSize(10)
                        .foregroundStyle(Theme.Colors.scout(scout.slot).opacity(0.3))
                }
                ForEach(scout.line) { point in
                    LineMark(x: .value("Seconds", point.time.timeIntervalSince(end)), y: .value("Signal", point.rssi),
                             series: .value("Scout", "\(scout.boardId) \(point.segment)"))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(Theme.Colors.scout(scout.slot))
                }
            }
            // The current value of each Scout, ringed in the panel color so it stands off the lines.
            ForEach(scouts) { scout in
                if let latest = scout.latest {
                    let x = PlottableValue.value("Seconds", latest.time.timeIntervalSince(end))
                    let y = PlottableValue.value("Signal", latest.rssi)
                    PointMark(x: x, y: y)
                        .symbol(symbol(scout.slot))
                        .symbolSize(130)
                        .foregroundStyle(Theme.Colors.panel)
                    PointMark(x: x, y: y)
                        .symbol(symbol(scout.slot))
                        .symbolSize(60)
                        .foregroundStyle(Theme.Colors.scout(scout.slot))
                }
            }
        }
        .chartXScale(domain: -Self.window...0)
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: [-120, -90, -60, -30, 0]) { value in
                AxisGridLine()
                if let seconds = value.as(Double.self), seconds.truncatingRemainder(dividingBy: 60) == 0 {
                    AxisValueLabel(seconds == 0 ? "Now" : "\(Int(-seconds / 60)) min ago",
                                   anchor: seconds == 0 ? .topTrailing : .top)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .stride(by: 10)) { value in
                AxisGridLine()
                AxisValueLabel { if let dBm = value.as(Int.self) { Text("\(dBm)") } }
            }
        }
        .frame(height: 180)
    }

    private func readout(strongest: ScoutSeries?, multiple: Bool, latestTime: Date, now: Date) -> some View {
        let value = strongest?.latest.map { Int($0.rssi.rounded()) }
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                    Text(value.map(String.init) ?? "--")
                        .font(Theme.Fonts.timer)
                        .foregroundStyle(value.map { Theme.Colors.signal(Int32(clamping: $0)) } ?? Theme.Colors.ink2)
                    Text("dBm")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.Colors.ink2)
                }
                Text(multiple && strongest != nil ? "Strongest: \(name(strongest!.boardId))" : "Average of the last few seconds")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.ink3)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
                Text(age(latestTime, now: now))
                    .font(Theme.Fonts.counter)
                    .foregroundStyle(Theme.Colors.ink2)
                if let low = points.map(\.rssi).min(), let high = points.map(\.rssi).max() {
                    Text("Range \(low) to \(high)")
                        .font(Theme.Fonts.counter)
                        .foregroundStyle(Theme.Colors.ink3)
                }
            }
        }
    }

    /// Names each Scout next to its marker and smoothed value.
    private func legend(_ scouts: [ScoutSeries]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                  alignment: .leading, spacing: Theme.Spacing.xs) {
            ForEach(scouts) { scout in
                HStack(spacing: Theme.Spacing.s) {
                    symbol(scout.slot)
                        .fill(Theme.Colors.scout(scout.slot))
                        .frame(width: 9, height: 9)
                    Text(name(scout.boardId))
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.ink)
                    Text(scout.latest.map { "\(Int($0.rssi.rounded()))" } ?? "")
                        .font(Theme.Fonts.caption.monospacedDigit())
                        .foregroundStyle(Theme.Colors.ink2)
                }
            }
        }
    }

    private func symbol(_ slot: Int) -> BasicChartSymbolShape {
        Self.symbols[slot % Self.symbols.count]
    }

    private func name(_ boardId: String) -> String {
        app.boardName(BoardID(rawValue: boardId))
    }

    private func age(_ time: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(time)))
        if seconds < 2 { return "Just now" }
        if seconds < 60 { return "\(seconds) s ago" }
        return "\(seconds / 60) min ago"
    }

    /// Whole 10 dB steps around the readings, at least 30 dB tall, so small swings do not look dramatic.
    private var yDomain: ClosedRange<Int> {
        let values = points.map(\.rssi)
        let low = Int((Double(values.min() ?? -90) / 10).rounded(.down)) * 10
        let high = Int((Double(values.max() ?? -50) / 10).rounded(.up)) * 10
        return low...max(high, low + 30)
    }

    private func summary(scouts: [ScoutSeries], strongest: ScoutSeries?) -> String {
        let values = points.map(\.rssi)
        guard let min = values.min(), let max = values.max(), let strongest, let latest = strongest.latest else { return "" }
        let scoutsText = scouts.count > 1 ? " from \(name(strongest.boardId)), strongest of \(scouts.count) Scouts" : ""
        return "Now \(Int(latest.rssi.rounded())) dBm\(scoutsText). \(points.count) readings from \(min) to \(max) dBm"
    }
}
