import SurveyCore
import UIKit

/// Owns the app model so work can start before any scene exists: after a
/// Bluetooth state restoration relaunch the app runs in the background, and
/// a running survey must resume there. A relaunch for background uploads alone
/// does not resume anything.
final class AppDelegate: NSObject, UIApplicationDelegate {
    lazy var model = AppModel()

    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Before the model exists, so a crash while it starts is reported.
        CrashReportingController.apply(enabled: SettingsStore()[Settings.crashReports])
        let restored = launchOptions?[.bluetoothCentrals] != nil
        let model = model
        Task { await model.launch(restoredByBluetooth: restored) }
        return true
    }

    /// NS Analytics uploads finished while the app was not running.
    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == AppModel.backgroundUploadIdentifier, let transport = model.uploadTransport else {
            completionHandler()
            return
        }
        // UIKit calls the handler on the main thread; the session reports from its own queue.
        nonisolated(unsafe) let completion = completionHandler
        transport.eventsFinished = {
            DispatchQueue.main.async { completion() }
        }
    }
}
