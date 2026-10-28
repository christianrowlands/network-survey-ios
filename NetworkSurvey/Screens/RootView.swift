import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var screens: DataScreens?

    var body: some View {
        if let screens {
            tabs.dataScreens(screens)
        } else {
            Color.clear.onAppear { screens = DataScreens(app: model) }
        }
    }

    private var tabs: some View {
        @Bindable var model = model
        return TabView(selection: $model.selectedTab) {
            Tab("Survey", systemImage: "dot.radiowaves.left.and.right", value: .survey) {
                SurveyView()
            }
            Tab("Map", systemImage: "map", value: .map) {
                MapScreen()
            }
            Tab("Lists", systemImage: "list.bullet", value: .lists) {
                ListsScreen()
            }
            Tab("Files", systemImage: "folder", value: .files) {
                FilesScreen()
            }
            Tab("Settings", systemImage: "gearshape", value: .settings) {
                SettingsScreen()
            }
        }
        .onChange(of: model.selectedTab) { model.updateIdleTimer() }
        .fullScreenCover(isPresented: $model.showingWelcome) { WelcomeView() }
        .fullScreenCover(isPresented: $model.showingNearby) { NearbyScreen() }
    }
}

#Preview {
    RootView().environment(AppModel(options: LaunchOptions(defaults: UserDefaults(suiteName: "preview") ?? .standard)))
}
