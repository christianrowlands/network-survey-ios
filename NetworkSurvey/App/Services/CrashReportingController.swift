import CrashReporting
import Foundation

/// Starts and stops crash reporting to match the Send crash reports setting.
/// Only a build with a Sentry DSN (Info.plist `SentryDSN`, from SENTRY_DSN in
/// Config/Local.xcconfig) reports; test runs and UI-testing launches never do.
enum CrashReportingController {
    private static let configuration: CrashReporter.Configuration? = {
        let bundle = Bundle.main
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        #if DEBUG
        let environment = "debug"
        #else
        let environment = "production"
        #endif
        return CrashReporter.Configuration(
            dsn: bundle.object(forInfoDictionaryKey: "SentryDSN") as? String,
            release: "\(bundle.bundleIdentifier ?? "app.networksurvey.ios")@\(bundle.shortVersion)+\(build)",
            environment: environment)
    }()

    /// Whether this build can send crash reports, so the setting is shown.
    static var isAvailable: Bool { configuration != nil && !isTesting }

    private static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || UserDefaults.standard.bool(forKey: "NSUITesting")
    }

    static func apply(enabled: Bool) {
        guard let configuration, !isTesting else { return }
        if enabled {
            CrashReporter.start(configuration)
        } else {
            CrashReporter.stop()
        }
    }

    /// Crashes the app on purpose, to check a build's crash reporting.
    static func crash() {
        CrashReporter.crash()
    }
}
