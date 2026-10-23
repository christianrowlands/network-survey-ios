import BoardKit
import SurveyCore
import SwiftUI
import UIKit

/// The Recording state: the hero (elapsed time, proof of life, mission ID),
/// the boards, live counts per protocol, and where the data is going.
struct SurveyRecordingBody: View {
    @Environment(AppModel.self) private var model
    let onSelectBoard: (BoardID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            RecordingHero()
            SectionHeader(title: "Boards", trailing: "\(model.boardManager.readyBoards.count) connected")
            BoardStrip(onSelect: onSelectBoard)
            SectionHeader(title: "Records", trailing: "unique this survey")
            ProtocolCounts()
            SectionHeader(title: "Where it's going")
            Panel {
                let destinations = activeDestinations
                if destinations.isEmpty {
                    Text("Nothing is saved or sent in this survey.")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.Colors.ink2)
                }
                ForEach(Array(destinations.enumerated()), id: \.element) { index, destination in
                    if index > 0 { Divider().overlay(Theme.Colors.rule) }
                    LiveDestinationRow(destination: destination)
                }
            }
        }
    }

    private var activeDestinations: [SurveyDestination] {
        let kinds = Set(model.survey.destinations.map(\.name))
        return SurveyDestination.allCases.filter { destination in
            destination.kinds.contains { kinds.contains($0.rawValue) }
        }
    }
}

private struct RecordingHero: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        let survey = model.survey
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = context.date.timeIntervalSince(survey.startedAt ?? context.date)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack(spacing: Theme.Spacing.s) {
                        Dot(color: survey.state == .stopping ? Theme.Colors.amber : Theme.Colors.red, size: 10)
                        Text(survey.state == .stopping ? "Stopping" : "Recording")
                            .font(Theme.Fonts.label)
                            .foregroundStyle(survey.state == .stopping ? Theme.Colors.amberText : Theme.Colors.red)
                    }
                    Text(ElapsedFormat.string(elapsed))
                        .font(Theme.Fonts.timer)
                        .foregroundStyle(Theme.Colors.ink)
                        .accessibilityIdentifier("survey.elapsed")
                    Label(heartbeat(now: context.date), systemImage: "checkmark.circle")
                        .font(Theme.Fonts.body.monospacedDigit())
                        .foregroundStyle(stalled(now: context.date) ? Theme.Colors.red : Theme.Colors.ink2)
                        .accessibilityIdentifier("survey.heartbeat")
                }
            }
            Label(locationLine, systemImage: locationSymbol)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Colors.ink2)
            if let missionId = survey.missionId {
                Divider().overlay(Theme.Colors.rule).padding(.vertical, Theme.Spacing.xs)
                HStack(spacing: Theme.Spacing.s) {
                    Text("Mission ID")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.ink2)
                    Text(missionId)
                        .font(Theme.Fonts.mono)
                        .foregroundStyle(Theme.Colors.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Mission ID \(missionId)")
                        .accessibilityIdentifier("survey.missionId")
                        .contextMenu {
                            Button("Copy mission ID", systemImage: "doc.on.doc") { copy(missionId) }
                        }
                    Button {
                        copy(missionId)
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .frame(width: Theme.Spacing.touchTarget, height: Theme.Spacing.touchTarget)
                    }
                    .accessibilityLabel(copied ? "Mission ID copied" : "Copy mission ID")
                }
            }
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Theme.Colors.redSoft, Theme.Colors.panel], startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
        )
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func copy(_ missionId: String) {
        UIPasteboard.general.string = missionId
        copied = true
    }

    private var total: Int {
        model.survey.counters.delivered.filter { $0.key != .deviceStatus }.values.reduce(0, +)
    }

    private func heartbeat(now: Date) -> String {
        let records = "\(total.formatted()) \(total == 1 ? "record" : "records")"
        guard let last = model.survey.counters.lastRecordAt else { return "\(records) · waiting for the first record" }
        let seconds = Int(now.timeIntervalSince(last))
        let beat = switch seconds {
        case ..<3: "last one just now"
        case ..<60: "last one \(seconds) s ago"
        default: "last one \(seconds / 60) min ago"
        }
        return "\(records) · \(beat)"
    }

    private func stalled(now: Date) -> Bool {
        guard let last = model.survey.counters.lastRecordAt else { return false }
        return now.timeIntervalSince(last) > 60
    }

    private var demoLocation: Bool {
        let ready = model.boardManager.readyBoards
        return !ready.isEmpty && ready.allSatisfy(model.isDemo)
    }

    private var locationLine: String {
        guard let fix = model.survey.location else {
            return model.access.location.isAllowed || demoLocation ? "Finding location" : "No location: records are not placed on the map"
        }
        let accuracy = fix.horizontalAccuracy.map { "±\(Int($0.rounded())) m" } ?? "accuracy unknown"
        let source = demoLocation ? "Demo location" : fix.source == .boardGPS ? "Board GPS" : "Location"
        return "\(source) · \(accuracy)"
    }

    private var locationSymbol: String {
        guard let fix = model.survey.location else { return "location.slash" }
        return (fix.horizontalAccuracy ?? 100) <= 20 ? "location.fill" : "location"
    }
}

/// Live counts for each protocol in the session.
private struct ProtocolCounts: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let survey = model.survey
        let session = survey.session
        let counts = survey.uniqueCounts
        Panel {
            if session?.wifiAP ?? true {
                row("Wi-Fi APs", symbol: SurveyProtocol.wifiAP.symbol, color: SurveyProtocol.wifiAP.color,
                    unique: counts.accessPoints, records: delivered(.wifiBeacon))
            }
            if session?.wifiClient ?? true {
                Divider().overlay(Theme.Colors.rule)
                row("Wi-Fi Clients", symbol: SurveyProtocol.wifiClient.symbol, color: Theme.Colors.wifiClient,
                    unique: counts.clients, records: delivered(.wifiStation))
                Divider().overlay(Theme.Colors.rule)
                row("Probe requests", subtitle: "Client and network pairs", symbol: "magnifyingglass",
                    color: Theme.Colors.wifiClient, unique: counts.probes, records: delivered(.wifiProbeRequest))
            }
            if session?.ble ?? false {
                Divider().overlay(Theme.Colors.rule)
                row("BLE devices", symbol: SurveyProtocol.ble.symbol, color: SurveyProtocol.ble.color,
                    unique: counts.bleDevices, records: delivered(.bluetooth))
            }
            if session?.rawFrames ?? false {
                Divider().overlay(Theme.Colors.rule)
                row("Raw frames", symbol: SurveyProtocol.rawFrames.symbol, color: SurveyProtocol.rawFrames.color,
                    unique: survey.counters.rawFrames, records: nil, unit: "frames")
            }
        }
        .accessibilityIdentifier("survey.counts")
    }

    private func delivered(_ type: MessageType) -> Int {
        model.survey.counters.delivered[type] ?? 0
    }

    private func row(
        _ title: String, subtitle: String? = nil, symbol: String, color: Color, unique: Int, records: Int?,
        unit: String? = nil
    ) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(Theme.Fonts.rowTitle)
                    .foregroundStyle(Theme.Colors.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.ink2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(unique.formatted())
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.Colors.ink)
                    .contentTransition(.numericText())
                Text([records.map { "\($0.formatted()) records" }, unit].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.Fonts.caption.monospacedDigit())
                    .foregroundStyle(Theme.Colors.ink2)
            }
        }
        .frame(minHeight: Theme.Spacing.rowMinHeight)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("survey.count.\(title)")
    }
}

private struct LiveDestinationRow: View {
    @Environment(AppModel.self) private var model
    let destination: SurveyDestination

    var body: some View {
        let snapshots = Dictionary(model.survey.destinations.map { ($0.name, $0.snapshot) }) { $1 }
        let status = LiveDestinationStatus.make(
            destination, snapshots: snapshots, upload: model.nsAnalyticsState,
            uploadIntervalMinutes: model.settings[Settings.nsAnalyticsUploadIntervalMinutes]
        )
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Image(systemName: destination.symbol)
                .foregroundStyle(Theme.Colors.ink2)
                .frame(width: 24)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(destination.title)
                    .font(Theme.Fonts.rowTitle)
                    .foregroundStyle(Theme.Colors.ink)
                ForEach(status.detail, id: \.self) { line in
                    Text(line)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if status.offersUpload {
                    Button(model.isUploading ? "Uploading" : "Upload now") {
                        Task { await model.uploadNow() }
                    }
                    .font(Theme.Fonts.body.weight(.semibold))
                    .buttonStyle(.borderless)
                    .disabled(model.isUploading)
                    .padding(.top, Theme.Spacing.xxs)
                }
            }
            Spacer(minLength: Theme.Spacing.s)
            StatusLabel(text: status.word, level: status.level)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .frame(minHeight: Theme.Spacing.touchTarget)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("survey.liveDestination.\(destination.title)")
    }
}
