import BoardKit
import BoardProtocol
import SwiftUI

#if DEBUG
/// Developer screen: live records from the first demo board, newest first.
struct DebugRecordsView: View {
    @Environment(AppModel.self) private var app
    @State private var model = DebugRecordsModel()

    var body: some View {
        List {
            Section {
                header
            }
            Section("Newest first") {
                ForEach(model.rows) { row in
                    RecordRow(row: row)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Live records")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("debugRecords.list")
        .task {
            await model.run(app: app)
        }
    }

    private var header: some View {
        let state = model.boardID.flatMap { app.boardManager.boards[$0] }
        let status = state?.status
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                Text(state?.info.map { "NS-\($0.shortID)" } ?? "Demo board")
                    .font(Theme.Fonts.sectionTitle)
                    .foregroundStyle(Theme.Colors.ink)
                TagPill(text: "Demo", color: Theme.Colors.accentInk)
                Spacer()
                Text(state?.connection.isConnected == true ? "Connected" : "Connecting…")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(state?.connection.isConnected == true ? Theme.Colors.green : Theme.Colors.amberText)
            }
            HStack(spacing: Theme.Spacing.l) {
                Metric(label: "Channel", value: status.map { $0.currentChannel == 0 ? "BLE" : "\($0.currentChannel)" } ?? "-")
                Metric(label: "Records/s", value: status.map { "\($0.recordsPerSec)" } ?? "-")
                Metric(label: "Total", value: "\(state?.recordCount ?? 0)")
                Metric(label: "Missed", value: "\(state?.missedNotifications ?? 0)")
            }
            HStack(spacing: Theme.Spacing.s) {
                ForEach([RecordSummary.Kind.ap, .client, .probe, .ble], id: \.self) { kind in
                    HStack(spacing: Theme.Spacing.xs) {
                        Dot(color: kind.color)
                        Text("\(kind.rawValue) \(model.counts[kind, default: 0])")
                            .font(Theme.Fonts.counter)
                            .foregroundStyle(Theme.Colors.ink2)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            if let error = model.error {
                Text(error).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.red)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}

private struct Metric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(value).font(Theme.Fonts.counter.weight(.semibold)).foregroundStyle(Theme.Colors.ink)
            Text(label).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.ink2)
        }
    }
}

private struct RecordRow: View {
    let row: RecordSummary

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Text(row.kind.rawValue)
                .font(Theme.Fonts.tag)
                .foregroundStyle(row.kind.color)
                .frame(width: 44, alignment: .leading)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(row.title)
                        .font(Theme.Fonts.rowTitle)
                        .foregroundStyle(Theme.Colors.ink)
                        .lineLimit(1)
                    ForEach(row.tags, id: \.self) { tag in
                        TagPill(text: tag, color: tag.tagColor)
                    }
                }
                Text(row.identifier)
                    .font(Theme.Fonts.mono)
                    .foregroundStyle(Theme.Colors.ink2)
                Text(row.detail)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.ink3)
            }
            Spacer(minLength: 0)
            if let rssi = row.rssi {
                Text("\(rssi)")
                    .font(Theme.Fonts.counter.weight(.semibold))
                    .foregroundStyle(Theme.Colors.signal(rssi))
                    .accessibilityLabel("\(rssi) dBm")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("debugRecords.row")
    }
}

private extension RecordSummary.Kind {
    var color: Color {
        switch self {
        case .ap: Theme.Colors.wifi
        case .client, .probe: Theme.Colors.wifi.opacity(0.75)
        case .ble: Theme.Colors.bluetooth
        case .gps: Theme.Colors.gnss
        }
    }
}

private extension String {
    var tagColor: Color {
        switch self {
        case "Open": Theme.Colors.tagOpen
        case "Hidden": Theme.Colors.tagHidden
        case "Random MAC", "Random": Theme.Colors.tagRandomized
        default: Theme.Colors.tagSecurity
        }
    }
}

/// Connects the first demo board, starts it and keeps the newest records.
/// Rows are published twice a second so the list does not redraw per record.
@Observable
final class DebugRecordsModel {
    static let maxRows = 200

    private(set) var rows: [RecordSummary] = []
    private(set) var counts: [RecordSummary.Kind: Int] = [:]
    private(set) var boardID: BoardID?
    private(set) var error: String?
    @ObservationIgnored private var nextID = 0

    func run(app: AppModel) async {
        let manager = app.boardManager
        guard let id = app.demoTransport.profiles.first?.id else { return }
        boardID = id
        let batches = manager.recordBatches()
        if manager.boards[id]?.connection.isConnected != true {
            do {
                try await manager.connect(id)
                var configure = NSBConfigure()
                configure.wifiAp = true
                configure.wifiClient = true
                configure.wifiProbes = true
                configure.ble = true
                configure.role = .auto
                try await manager.configure(id, configure)
                try await manager.start(id)
            } catch {
                self.error = "Demo board: \(error)"
            }
        }
        var pending: [RecordSummary] = []
        var pendingCounts = counts
        var lastFlush = ContinuousClock.now
        for await (board, received) in batches where board == id {
            for record in received.batch.records {
                guard let row = RecordSummary(record: record, id: nextID) else { continue }
                nextID += 1
                pending.append(row)
                pendingCounts[row.kind, default: 0] += 1
            }
            if ContinuousClock.now - lastFlush > .milliseconds(500) {
                rows = Array((pending.reversed() + rows).prefix(Self.maxRows))
                counts = pendingCounts
                pending.removeAll()
                lastFlush = .now
            }
        }
    }
}
#endif
