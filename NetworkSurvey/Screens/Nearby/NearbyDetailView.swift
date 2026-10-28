import Charts
import NearbyKit
import SwiftUI

/// One device heard by this iPhone. No address: iOS doesn't give one.
struct NearbyDetailView: View {
    let nearby: NearbyModel
    let id: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let device = nearby.devices.first(where: { $0.id == id }) {
                content(device)
            } else {
                ContentUnavailableView("Not in the list", systemImage: "iphone",
                                       description: Text("This device was hidden or hasn't been heard for a while."))
            }
        }
        .themedList()
        .navigationTitle("Nearby device")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ device: NearbyDevice) -> some View {
        List {
            Group {
                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Text(device.name ?? "Unnamed device")
                            .font(Theme.Fonts.screenTitle)
                            .foregroundStyle(Theme.Colors.ink)
                            .accessibilityAddTraits(.isHeader)
                        NearbySourceLabel()
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                }
                Section("Signal") {
                    NearbySignalChart(readings: device.history)
                        .padding(.vertical, Theme.Spacing.xs)
                }
                Section("Advertisement") {
                    if let company = device.companyID {
                        DetailRow(label: "Company", value: NearbyFormat.company(company))
                    }
                    ForEach(device.serviceUUIDs, id: \.self) { uuid in
                        ServiceRow(uuid: uuid)
                    }
                    ForEach(device.serviceDataUUIDs, id: \.self) { uuid in
                        DetailRow(label: "Service data", value: BLEServiceUUIDs.name(forUUID: uuid) ?? BLEServiceUUIDs.display(uuid))
                    }
                    if let txPower = device.txPower {
                        DetailRow(label: "TX power", value: DataFormat.dBm(txPower))
                    }
                    if let connectable = device.isConnectable {
                        DetailRow(label: "Connectable", value: connectable ? "Yes" : "No")
                    }
                    if let data = device.manufacturerData, !data.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text("Manufacturer data")
                                .font(Theme.Fonts.label)
                                .foregroundStyle(Theme.Colors.ink2)
                            Text(DataFormat.hex(data))
                                .font(Theme.Fonts.mono)
                                .foregroundStyle(Theme.Colors.ink)
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Section {
                    DetailRow(label: "Last signal", value: DataFormat.dBm(device.rssi))
                    DetailRow(label: "First heard", value: device.firstHeard.formatted(date: .omitted, time: .standard))
                    DetailRow(label: "Last heard", value: device.lastHeard.formatted(date: .omitted, time: .standard))
                } header: {
                    Text("Heard")
                } footer: {
                    Text("iPhones hide Bluetooth addresses from apps. Without an NS Scout, this app can't tell you which device this is over time.")
                }
                Section {
                    Button("Hide for now") {
                        nearby.hide(id)
                        dismiss()
                    }
                    .accessibilityIdentifier("nearby.hide")
                } footer: {
                    Text("Hidden until you close Nearby Bluetooth.")
                }
            }
            .panelRows()
        }
        .listStyle(.insetGrouped)
    }
}

/// Signal over the last two minutes, in the neutral color of these screens.
private struct NearbySignalChart: View {
    let readings: [NearbyReading]

    var body: some View {
        if readings.count < 2 {
            Text("Signal history appears after a few observations.")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Colors.ink2)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let end = max(context.date, readings.last?.time ?? context.date)
                let shown = readings.filter { end.timeIntervalSince($0.time) <= NearbyDeviceList.historyWindow }
                Chart(Array(shown.enumerated()), id: \.offset) { _, reading in
                    LineMark(x: .value("Seconds", reading.time.timeIntervalSince(end)), y: .value("Signal", reading.rssi))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(Theme.Colors.ink2)
                }
                .chartXScale(domain: -NearbyDeviceList.historyWindow...0)
                .chartPlotStyle { $0.clipped() }
                .chartXAxis {
                    AxisMarks(values: [-120, -60, 0]) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let seconds = value.as(Double.self) {
                                Text(seconds == 0 ? "now" : "\(Int(-seconds / 60)) min")
                            }
                        }
                    }
                }
                .frame(height: 140)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Signal over the last two minutes")
            .accessibilityValue(readings.last.map { DataFormat.dBm($0.rssi) } ?? "")
        }
    }
}
