import Destinations
import SurveyCore
import SwiftUI

/// The shared state of the Map, Lists, Files and Settings tabs, built once
/// from the app model.
@MainActor
final class DataScreens {
    let data: SurveyData
    let settings: SettingsModel
    let registration: RegistrationModel
    let mapCommands = MapCommands()
    let lists = ListsNavigation()

    init(app: AppModel) {
        data = SurveyData(store: app.store)
        settings = SettingsModel(store: app.settings)
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
            .modifier(RegistrationLinkHandling(registration: screens.registration))
    }
}
