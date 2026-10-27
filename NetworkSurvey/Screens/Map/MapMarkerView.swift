import SurveyCore
import SwiftUI

/// A map marker: an icon for one item, a counted bubble for a cluster.
struct MapMarkerView: View {
    let cluster: MapCluster<MapPoint>
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if cluster.isSingle {
                single(cluster.points[0])
            } else {
                bubble
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(cluster.isSingle ? "Shows details" : "Zooms in")
    }

    private func single(_ point: MapPoint) -> some View {
        Image(systemName: Self.symbol(point.kind))
            .font(.caption.weight(.semibold))
            .foregroundStyle(Self.glyphColor(point.kind))
            .frame(width: 28, height: 28)
            .background(Self.color(point.kind), in: Circle())
            .overlay {
                if point.kind != .ble {
                    Circle().stroke(DataFormat.bandColor(point.band), lineWidth: 2.5)
                }
            }
            .shadow(color: Theme.Colors.shadow, radius: 2, y: 1)
            .frame(width: Theme.Spacing.touchTarget, height: Theme.Spacing.touchTarget)
            .contentShape(Rectangle())
    }

    /// A count on the panel color with a ring split by kind (APs, clients, BLE).
    private var bubble: some View {
        let total = Double(cluster.points.count)
        let counts = Dictionary(grouping: cluster.points, by: \.kind).mapValues { Double($0.count) }
        let kinds: [ObservationKind] = [.ap, .client, .ble].filter { counts[$0] != nil }
        let size = min(30 + CGFloat(log2(total)) * 3, 44)
        return ZStack {
            Circle().fill(Theme.Colors.panel)
            ForEach(Array(kinds.enumerated()), id: \.offset) { index, kind in
                let start = kinds.prefix(index).reduce(0) { $0 + (counts[$1] ?? 0) } / total
                let end = start + (counts[kind] ?? 0) / total
                Circle()
                    .trim(from: start, to: end)
                    .stroke(Self.color(kind), lineWidth: 4)
                    .rotationEffect(.degrees(-90))
                    .padding(2)
            }
            Text(cluster.points.count < 1000 ? "\(cluster.points.count)" : "999+")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(Theme.Colors.ink)
                .minimumScaleFactor(0.7)
                .padding(Theme.Spacing.xs)
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.Colors.shadow, radius: 2, y: 1)
        .frame(minWidth: Theme.Spacing.touchTarget, minHeight: Theme.Spacing.touchTarget)
        .contentShape(Rectangle())
    }

    private var accessibilityText: String {
        if cluster.isSingle {
            let point = cluster.points[0]
            let name = point.label?.isEmpty == false ? point.label! : point.identity
            return "\(Self.kindName(point.kind, count: 1)) \(name), strongest \(point.rssi) dBm"
        }
        let parts = Dictionary(grouping: cluster.points, by: \.kind)
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.value.count) \(Self.kindName($0.key, count: $0.value.count))" }
        return "Group of \(cluster.points.count): " + parts.joined(separator: ", ")
    }

    static func symbol(_ kind: ObservationKind) -> String {
        switch kind {
        case .ap: "wifi"
        case .client, .probe: "iphone"
        case .ble: "dot.radiowaves.right"
        }
    }

    static func color(_ kind: ObservationKind) -> Color {
        switch kind {
        case .ap: Theme.Colors.wifi
        case .client, .probe: Theme.Colors.wifiClient
        case .ble: Theme.Colors.bluetooth
        }
    }

    static func glyphColor(_ kind: ObservationKind) -> Color {
        kind == .client || kind == .probe ? Theme.Colors.onWifiClient : Theme.Colors.onAccent
    }

    static func kindName(_ kind: ObservationKind, count: Int) -> String {
        switch kind {
        case .ap: count == 1 ? "access point" : "access points"
        case .client, .probe: count == 1 ? "client" : "clients"
        case .ble: count == 1 ? "Bluetooth device" : "Bluetooth devices"
        }
    }
}
