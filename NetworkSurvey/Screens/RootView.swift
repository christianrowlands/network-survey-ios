import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var screens: DataScreens?

    var body: some View {
        if let screens {
            tabs.appAppearance()
                .dataScreens(screens)
                // A new survey is what Map and Signals should show, not a past one left picked.
                .onChange(of: model.survey.state) { old, new in
                    if old == .idle && new != .idle { screens.data.showLive() }
                }
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
            Tab("Signals", systemImage: "list.bullet", value: .signals) {
                ListsScreen()
            }
            Tab("Map", systemImage: "map", value: .map) {
                MapScreen()
            }
            Tab("Tools", systemImage: "wrench.and.screwdriver", value: .tools) {
                ToolsScreen()
            }
            Tab("Settings", systemImage: "gearshape", value: .settings) {
                SettingsScreen()
            }
        }
        .onChange(of: model.selectedTab) { model.updateIdleTimer() }
        .fullScreenCover(isPresented: $model.showingWelcome) { WelcomeView() }
        .fullScreenCover(isPresented: $model.showingNearby) { NearbyScreen() }
        .sheet(isPresented: $model.showingWatchlistHistory) {
            NavigationStack {
                WatchlistHistoryScreen()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { model.showingWatchlistHistory = false }
                                .accessibilityIdentifier("watchlistHistory.done")
                        }
                    }
            }
        }
        .sheet(item: $model.filesRequest) { request in
            NavigationStack {
                FilesPage(focusMissionID: request.missionID)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { model.filesRequest = nil }
                                .accessibilityIdentifier("files.done")
                        }
                    }
            }
        }
    }
}

#Preview {
    RootView().environment(AppModel(options: LaunchOptions(defaults: UserDefaults(suiteName: "preview") ?? .standard)))
}
