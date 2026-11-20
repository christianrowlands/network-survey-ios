import Charts
import SurveyCore
import SwiftUI

/// One band's channel occupancy: each access point is a curve over the
/// channels it uses, as high as its signal, named where there is room.
/// Tapping a curve opens it.
struct SpectrumChart: View {
    let section: WifiSpectrum.Section
    let placements: [WifiSpectrum.Placement]
    let onSelect: (WifiSpectrum.Placement) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 250

    /// The frame each channel number is centered in.
    private static let tickWidth: CGFloat = 24

    var body: some View {
        let labeled = WifiSpectrum.labeled(placements, in: section)
        let top = WifiSpectrum.top(for: placements)
        // Signal grid lines every 10 dB; every other one is labeled.
        let levels = Array(stride(from: WifiSpectrum.floorDBm + 10, to: top, by: 10))
        Chart {
            // Strongest first, so a weak curve is drawn over a strong one, not hidden behind it.
            ForEach(placements.sorted { ($0.peak, $1.bssid) > ($1.peak, $0.bssid) }) { placement in
                let color = Theme.Colors.spectrum(placement.colorSlot)
                ForEach(placement.outline().filter { section.domain.contains($0.x) }, id: \.index) { point in
                    AreaMark(
                        x: .value("Channel", point.x), yStart: .value("Floor", WifiSpectrum.floorDBm),
                        yEnd: .value("Signal", point.dBm), series: .value("Access point", placement.bssid)
                    )
                    .foregroundStyle(color.opacity(0.1))
                    LineMark(
                        x: .value("Channel", point.x), y: .value("Signal", point.dBm),
                        series: .value("Access point", placement.bssid)
                    )
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
            ForEach(placements.filter { labeled.contains($0.bssid) }) { placement in
                PointMark(x: .value("Channel", Double(placement.center)), y: .value("Signal", placement.peak))
                    .symbolSize(0)
                    .annotation(position: .top, spacing: Theme.Spacing.xxs,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        label(placement)
                    }
            }
        }
        .chartXScale(domain: section.domain)
        .chartYScale(domain: WifiSpectrum.floorDBm...top)
        .chartXAxis {
            AxisMarks(values: section.primaries.map(Double.init)) { value in
                AxisGridLine()
                if let channel = value.as(Double.self), section.ticks.contains(Int(channel)) {
                    // Charts puts a label's leading edge at its line, so the number
                    // is centered in a fixed frame pulled back by half its width.
                    AxisValueLabel(anchor: .top, collisionResolution: .disabled, horizontalSpacing: 0) {
                        Text("\(Int(channel))")
                            .fixedSize()
                            .frame(width: Self.tickWidth)
                            .offset(x: -Self.tickWidth / 2)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: levels) { value in
                AxisGridLine()
                if let dBm = value.as(Double.self), Int(dBm) % 20 == -10 {
                    AxisValueLabel("\(Int(dBm))")
                }
            }
        }
        .chartXAxisLabel("Channel", alignment: .center)
        .chartYAxisLabel("dBm", position: .topLeading)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { location in select(at: location, proxy: proxy, geometry: geometry) }
            }
        }
        .overlay {
            if placements.isEmpty {
                Text(SpectrumPresentation.empty(section))
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.ink2)
                    .multilineTextAlignment(.center)
                    .padding(Theme.Spacing.s)
                    .background(Theme.Colors.panel.opacity(0.9), in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
            }
        }
        .frame(height: min(height, 360))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: placements)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(SpectrumPresentation.title(section)) spectrum")
        .accessibilityValue(SpectrumPresentation.summary(placements, in: section))
        .accessibilityHint(placements.isEmpty ? "" : "Each access point is listed below the chart")
        .accessibilityIdentifier("spectrum.chart")
    }

    /// A network name on the panel color, so it reads over other curves.
    private func label(_ placement: WifiSpectrum.Placement) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Circle()
                .fill(Theme.Colors.spectrum(placement.colorSlot))
                .frame(width: 6, height: 6)
            Text(SpectrumPresentation.chartLabel(placement))
                .font(Theme.Fonts.tag)
                .foregroundStyle(placement.ssid == nil ? Theme.Colors.ink2 : Theme.Colors.ink)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, Theme.Spacing.xs)
        .padding(.vertical, 1)
        .background(Theme.Colors.panel.opacity(0.85), in: Capsule())
        .frame(maxWidth: 110)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func select(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plot = proxy.plotFrame else { return }
        let origin = geometry[plot].origin
        let point = CGPoint(x: location.x - origin.x, y: location.y - origin.y)
        guard let (channel, dBm) = proxy.value(at: point, as: (Double, Double).self),
              let hit = WifiSpectrum.hit(x: channel, dBm: dBm, in: placements) else { return }
        onSelect(hit)
    }
}
