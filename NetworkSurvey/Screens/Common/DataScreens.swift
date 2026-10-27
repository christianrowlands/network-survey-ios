import Destinations
import SurveyCore
import SwiftUI
import Towers

/// The shared state of the Map, Lists, Files and Settings tabs, built once
/// from the app model.
@MainActor
final class DataScreens {
    let data: SurveyData
    let settings: SettingsModel
    let registration: RegistrationModel
    let mapCommands = MapCommands()
    let lists = ListsNavigation()
    let towers: TowerLayerModel

    init(app: AppModel) {
        data = SurveyData(store: app.store)
        settings = SettingsModel(store: app.settings)
        towers = TowerLayerModel(client: app.options.uiTesting
            ? TowerClient(config: TowerServiceConfig(apiKey: "ui-testing", bundleID: "test", appVersion: "test"),
                          transport: FixtureTowerTransport())
            : TowerClient(config: .app()))
        let identity = app.identity
        let appSettings = app.settings
        registration = RegistrationModel(
            client: app.nsAnalyticsClient, credentials: app.nsAnalyticsCredentials, settings: settings
        ) {
            let info = AppInfo(appVersion: Bundle.main.shortVersion)
            let name = appSettings[Settings.deviceName].trimmingCharacters(in: .whitespacesAndNewlines)
            return NSAnalyticsClient.DeviceInfo(
                deviceID: identity.deviceSerialNumber, deviceName: name.isEmpty ? DeviceIdentity.defaultName(installID: identity.installID) : name,
                deviceModel: info.deviceModel, osVersion: "iOS \(info.osVersion)", appVersion: info.appVersion
            )
        }
    }
}

extension View {
    /// Injects the data screens' state and handles registration links the app
    /// receives. Attach once, on the tab view.
    func dataScreens(_ screens: DataScreens) -> some View {
        environment(screens.data)
            .environment(screens.settings)
            .environment(screens.registration)
            .environment(screens.mapCommands)
            .environment(screens.lists)
            .environment(screens.towers)
            .modifier(RegistrationLinkHandling(registration: screens.registration))
    }
}
