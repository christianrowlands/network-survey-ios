import BoardProtocol
import SurveyCore
import SwiftUI

/// The access point list grouped by SSID: a row per network that opens to
/// its access points, each of which opens its detail.
struct AccessPointGroupRows: View {
    let groups: [AccessPointGroup]
    let sessionID: String
    @Binding var expanded: Set<String>

    var body: some View {
        ForEach(groups) { group in
            let isOpen = expanded.contains(group.key)
            Button {
                withAnimation(.snappy) { expanded.formSymmetricDifference([group.key]) }
            } label: {
                AccessPointGroupRowView(group: group, isOpen: isOpen)
            }
            .listRowBackground(isOpen ? Theme.Colors.panel : Theme.Colors.ground)
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            .accessibilityHint(isOpen ? "Hides its access points" : "Shows its access points")
            .accessibilityIdentifier("lists.group")
            if isOpen {
                ForEach(group.members, id: \.bssid) { ap in
                    NavigationLink(value: DetailRoute.accessPoint(sessionID: sessionID, bssid: ap.bssid)) {
                        AccessPointRowView(ap: ap)
                            .padding(.leading, Theme.Spacing.l)
                    }
                    .listRowBackground(Theme.Colors.panel)
                }
            }
        }
    }
}

struct AccessPointGroupRowView: View {
    let group: AccessPointGroup
    let isOpen: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(DataFormat.ssid(group.ssid, hidden: group.hidden))
                    .font(Theme.Fonts.rowTitle.weight(.medium))
                    .foregroundStyle(group.ssid == nil ? Theme.Colors.ink2 : Theme.Colors.ink)
                    .lineLimit(1)
                if group.ssid == nil {
                    // Hidden and unnamed networks are one access point each.
                    AddressLine(address: group.bssid, vendor: OUIRegistry.shortVendor(for: group.bssid))
                } else {
                    Text(DataFormat.count(group.accessPointCount, "access point"))
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.Colors.ink2)
                }
                TagRow {
                    if group.securities.count == 1, let security = group.securities.first {
                        TagPill(text: DataFormat.security(security), color: DataFormat.securityColor(security))
                    } else if !group.securities.isEmpty {
                        // Several kinds: the weakest decides the color.
                        let weak = group.securities.contains { [.open, .wep].contains(NSBSecurityType(rawValue: $0)) }
                        TagPill(text: "Mixed security", color: weak ? Theme.Colors.tagOpen : Theme.Colors.tagSecurity)
                            .accessibilityLabel(group.securities.map(DataFormat.security).joined(separator: ", "))
                    }
                    ForEach(group.bands, id: \.self) { band in
                        BandTag(band: band, channel: 0)
                    }
                    if group.hidden { TagPill(text: "Hidden", color: Theme.Colors.tagHidden) }
                    WatchedTag(ssid: group.ssid, bssid: group.bssid, group: true)
                }
            }
            Spacer(minLength: Theme.Spacing.s)
            SignalColumn(rssi: group.rssiLast, lastSeen: group.lastSeen)
            Image(systemName: "chevron.right")
                .font(Theme.Fonts.caption.weight(.semibold))
                .foregroundStyle(Theme.Colors.ink3)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .accessibilityHidden(true)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

nonisolated enum GroupedOrder {
    /// `new` with the current order kept, for groups and for the access
    /// points of open groups (see `StableOrder`).
    static func merge(_ old: [AccessPointGroup], _ new: [AccessPointGroup]) -> [AccessPointGroup] {
        let previous = Dictionary(old.map { ($0.key, $0.members) }, uniquingKeysWith: { first, _ in first })
        return StableOrder.merge(old, new, id: \.key).map { group in
            guard let members = previous[group.key], !members.isEmpty else { return group }
            var merged = group
            merged.members = StableOrder.merge(members, group.members, id: \.bssid)
            return merged
        }
    }
}
