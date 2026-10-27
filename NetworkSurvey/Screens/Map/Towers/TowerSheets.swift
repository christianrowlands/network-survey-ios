import SwiftUI
import Towers

/// The tower layer's sheets and the one-time note on what it sends.
struct TowerSheets: ViewModifier {
    @Binding var selection: TowerSelection?
    @Binding var showingFilters: Bool
    @Binding var showingSearch: Bool
    @Binding var askingNotice: Bool
    let onFound: ([Tower]) -> Void
    let onAcceptNotice: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $selection) { selection in
                TowerDetailSheet(selection: selection)
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
            .sheet(isPresented: $showingFilters) {
                TowerFilterSheet()
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingSearch) {
                TowerSearchSheet(onFound: onFound)
                    .presentationDetents([.medium, .large])
            }
            .alert("Show cell towers?", isPresented: $askingNotice) {
                Button("Show Towers", action: onAcceptNotice)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Tower positions come from the Network Survey tower service, using OpenCelliD data. To find them, the app sends the area shown on the map to the service. Nothing from your surveys is sent.")
            }
    }
}
