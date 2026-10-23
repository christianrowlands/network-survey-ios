import SwiftUI

@main
struct NetworkSurveyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appDelegate.model)
                .tint(Theme.Colors.accent)
                .onOpenURL { appDelegate.model.handleOpenURL($0) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { appDelegate.model.handleOpenURL(url) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            appDelegate.model.scenePhaseChanged(active: phase == .active)
        }
    }
}
