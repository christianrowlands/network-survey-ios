import SwiftUI
import Towers

/// A tower marker: a rounded square in the operator's color (Wi-Fi markers are
/// round), or a counted bubble ringed by operator for a group.
struct TowerMarkerView: View {
    let cluster: MapCluster<Tower>
    var names: [Plmn: PlmnInfo] = [:]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if cluster.isSingle || cluster.isStack {
                single(cluster.points[0], count: cluster.points.count)
            } else {
                bubble
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(cluster.isSingle || cluster.isStack ? "Shows details" : "Zooms in")
        .accessibilityIdentifier(cluster.isSingle ? "map.tower" : "map.towerGroup")
    }

    private func single(_ tower: Tower, count: Int) -> some View {
        Image(systemName: "antenna.radiowaves.left.and.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.Colors.onAccent)
            .frame(width: 28, height: 28)
            .background(Self.color(tower.plmn), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.Colors.panel, lineWidth: 2))
            .overlay(alignment: .bottomTrailing) {
                Text(tower.technology?.generation ?? tower.radio)
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.Colors.ink)
                    .padding(.horizontal, 3)
                    .background(Theme.Colors.panel, in: Capsule())
                    .offset(x: 8, y: 6)
            }
            .overlay(alignment: .topTrailing) {
                if count > 1 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.Colors.onAccent)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Theme.Colors.ink, in: Capsule())
                        .offset(x: 8, y: -8)
                }
            }
            .shadow(color: Theme.Colors.shadow, radius: 2, y: 1)
            .frame(width: Theme.Spacing.touchTarget, height: Theme.Spacing.touchTarget)
            .contentShape(Rectangle())
    }

    /// The count, ringed by the share of each operator (the four largest, then gray).
    private var bubble: some View {
        let total = Double(cluster.points.count)
        let shares = Self.operatorShares(cluster.points)
        let size = min(30 + CGFloat(log2(total)) * 3, 44)
        return ZStack {
            RoundedRectangle(cornerRadius: size / 4).fill(Theme.Colors.panel)
            ForEach(Array(shares.enumerated()), id: \.offset) { index, share in
                let start = shares.prefix(index).reduce(0) { $0 + $1.count } / total
                RoundedRectangle(cornerRadius: size / 4)
                    .trim(from: start, to: start + share.count / total)
                    .stroke(share.color, lineWidth: 4)
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
        let tower = cluster.points[0]
        if cluster.isSingle { return Self.title(tower, names: names) }
        if cluster.isStack { return "\(cluster.points.count) towers at one site" }
        return "Group of \(cluster.points.count) towers"
    }

    static func color(_ plmn: Plmn) -> Color {
        Theme.Colors.operators[PlmnPalette.index(for: plmn)]
    }

    /// "ExampleNet 4G tower" or "310-410 4G tower".
    static func title(_ tower: Tower, names: [Plmn: PlmnInfo]) -> String {
        "\(names[tower.plmn]?.name ?? tower.plmn.description) \(tower.technology?.generation ?? tower.radio) tower"
    }

    private static func operatorShares(_ towers: [Tower]) -> [(color: Color, count: Double)] {
        let counts = Dictionary(grouping: towers, by: \.plmn).mapValues(\.count)
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        var shares = counts.prefix(4).map { (color: color($0.key), count: Double($0.value)) }
        let rest = counts.dropFirst(4).reduce(0) { $0 + $1.value }
        if rest > 0 { shares.append((Theme.Colors.ink3, Double(rest))) }
        return shares
    }
}

extension MapCluster where Point == Tower {
    /// Towers at one site, which no zoom level separates: a tap lists them.
    var isStack: Bool {
        guard points.count > 1 else { return false }
        let lats = points.map(\.lat), lons = points.map(\.lon)
        return lats.max()! - lats.min()! < 0.00005 && lons.max()! - lons.min()! < 0.00005
    }
}
