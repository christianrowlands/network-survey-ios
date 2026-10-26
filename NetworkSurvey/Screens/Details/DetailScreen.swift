import Charts
import SurveyCore
import SwiftUI

/// A detail screen to push from the Lists or the Map.
enum DetailRoute: Hashable {
    case accessPoint(sessionID: String, bssid: String)
    case client(sessionID: String, mac: String)
    /// A network name from probe requests; empty for wildcard probes.
    case probeNetwork(sessionID: String, ssid: String)
    case ble(sessionID: String, address: String)
}

struct DetailScreen: View {
    let route: DetailRoute

    var body: some View {
        switch route {
        case .accessPoint(let sessionID, let bssid): AccessPointDetailView(sessionID: sessionID, bssid: bssid)
        case .client(let sessionID, let mac): ClientDetailView(sessionID: sessionID, mac: mac)
        case .probeNetwork(let sessionID, let ssid): ProbeNetworkDetailView(sessionID: sessionID, ssid: ssid)
        case .ble(let sessionID, let address): BLEDetailView(sessionID: sessionID, address: address)
        }
    }
}

/// Keeps a detail query live while the survey writes.
struct LiveDetail<Updates: AsyncSequence, Value, Content: View>: View where Updates.Element == Value? {
    let query: (SurveyStore) -> Updates
    @ViewBuilder let content: (Value) -> Content

    @Environment(SurveyData.self) private var data
    @State private var value: Value?
    @State private var finished = false
    @State private var failure: String?

    init(query: @escaping (SurveyStore) -> Updates, @ViewBuilder content: @escaping (Value) -> Content) {
        self.query = query
        self.content = content
    }

    var body: some View {
        Group {
            if let failure {
                ContentUnavailableView("Could not read the survey", systemImage: "exclamationmark.triangle",
                                       description: Text(failure))
            } else if let value {
                content(value)
            } else if finished {
                ContentUnavailableView("Not found", systemImage: "questionmark.circle",
                                       description: Text("This item is no longer in the survey."))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            do {
                for try await next in query(data.store) {
                    value = next
                    if next == nil { break }
                }
            } catch is CancellationError {
            } catch {
                failure = error.localizedDescription
            }
            finished = true
        }
    }
}

/// Signal over time as a line, with the strongest value marked.
struct RSSIChart: View {
    let points: [RSSIPoint]

    var body: some View {
        if points.count < 2 {
            Text("Signal history appears after a few observations.")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Colors.ink2)
        } else {
            Chart(Array(points.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("Time", point.time), y: .value("Signal", point.rssi))
                    .foregroundStyle(Theme.Colors.accent)
            }
            .chartYAxisLabel("dBm")
            .chartYScale(domain: yDomain)
            .chartXAxis {
                AxisMarks(preset: .aligned, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: timeFormat)
                }
            }
            .frame(height: 140)
            .accessibilityElement()
            .accessibilityLabel("Signal over time")
            .accessibilityValue(summary)
        }
    }

    /// Seconds matter when the history spans only a few minutes.
    private var timeFormat: Date.FormatStyle {
        guard let first = points.first?.time, let last = points.last?.time,
              last.timeIntervalSince(first) < 600 else { return .dateTime.hour().minute() }
        return .dateTime.hour().minute().second()
    }

    private var yDomain: ClosedRange<Int> {
        let values = points.map(\.rssi)
        let low = (values.min() ?? -100) - 5
        let high = (values.max() ?? -30) + 5
        return low...max(high, low + 10)
    }

    private var summary: String {
        let values = points.map(\.rssi)
        guard let min = values.min(), let max = values.max(), let last = values.last else { return "" }
        return "\(points.count) readings, from \(min) to \(max) dBm, latest \(last) dBm"
    }
}

/// A label and value row for detail sections. Long identifiers use mono.
struct DetailRow: View {
    let label: String
    let value: String
    var mono = false

    var body: some View {
        LabeledContent(label) {
            Text(value)
                .font(mono ? Theme.Fonts.mono : Theme.Fonts.body)
                .foregroundStyle(Theme.Colors.ink)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

/// First seen, last seen, counts and signal, shared by the entity detail screens.
struct ObservationSection: View {
    let entity: any SurveyEntity

    var body: some View {
        Section("Observations") {
            DetailRow(label: "Last signal", value: DataFormat.dBm(entity.rssiLast))
            DetailRow(label: "Strongest", value: DataFormat.dBm(entity.rssiMax))
            DetailRow(label: "First seen", value: DataFormat.dateTime(entity.firstSeen))
            DetailRow(label: "Last seen", value: DataFormat.dateTime(entity.lastSeen))
            DetailRow(label: "Observations", value: DataFormat.count(entity.observationCount))
            DetailRow(label: "Frames", value: DataFormat.count(entity.frameCount))
            DetailRow(label: "Last heard by", value: entity.lastBoardId, mono: true)
            if let lat = entity.bestLatitude, let lon = entity.bestLongitude {
                DetailRow(label: "Strongest at", value: String(format: "%.5f, %.5f", lat, lon), mono: true)
            }
        }
    }
}
