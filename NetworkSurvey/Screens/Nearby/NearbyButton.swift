import SwiftUI

/// Opens Nearby Bluetooth from an empty Bluetooth list. Callers show it only
/// while no survey records.
struct NearbyButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.showingNearby = true
        } label: {
            Label("See what this iPhone hears nearby", systemImage: "iphone")
        }
        .buttonStyle(.bordered)
        .tint(Theme.Colors.accent)
        .accessibilityHint("Opens Nearby Bluetooth, which isn't part of a survey")
        .accessibilityIdentifier("lists.nearby")
    }
}
