import Foundation
import Sentry

/// Crash and hang reports, sent to Sentry. Only a build with a DSN configured
/// (SENTRY_DSN in Config/Local.xcconfig) reports anything; builds from source
/// have none and never start the SDK.
public enum CrashReporter {
    public struct Configuration: Sendable, Equatable {
        public let dsn: String
        public let release: String
        public let environment: String

        /// Nil without a usable DSN: empty, or left unexpanded by the build
        /// ("$(SENTRY_DSN)").
        public init?(dsn: String?, release: String, environment: String) {
            let dsn = dsn?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let url = URL(string: dsn), ["https", "http"].contains(url.scheme),
                  url.host() != nil, url.user() != nil
            else { return nil }
            self.dsn = dsn
            self.release = release
            self.environment = environment
        }
    }

    public static var isRunning: Bool { SentrySDK.isEnabled }

    public static func start(_ configuration: Configuration) {
        guard !isRunning else { return }
        SentrySDK.start { options in
            options.dsn = configuration.dsn
            options.releaseName = configuration.release
            options.environment = configuration.environment

            // Crashes, MetricKit hang and resource diagnostics, and sessions
            // for the crash-free rate. Sentry's own hang detector is
            // deprecated in favor of MetricKit.
            options.enableCrashHandler = true
            options.enableMetricKit = true
            options.enableAutoSessionTracking = true
            options.enableAppHangTracking = false

            // Survey screens show other people's network names and device
            // addresses, and upload URLs carry workspace details. So no
            // screenshots, view hierarchy, replay, network breadcrumbs, failed
            // request events, performance tracing or personal data.
            options.sendDefaultPii = false
            #if os(iOS)
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            options.sessionReplay.sessionSampleRate = 0
            options.sessionReplay.onErrorSampleRate = 0
            #endif
            options.enableNetworkBreadcrumbs = false
            options.enableCaptureFailedRequests = false
            options.enableNetworkTracking = false
            options.enableAutoPerformanceTracing = false
            options.tracesSampleRate = nil
            options.enableSwizzling = false

            // Keep only the SDK's random installation ID, which counts
            // affected users, and drop breadcrumb payloads. The app context's
            // device_app_hash is derived from the device, so it goes too.
            options.beforeSend = { event in
                let user = User()
                user.userId = event.user?.userId
                // Without an address, Sentry fills in the connection's IP and
                // estimates a location from it; this placeholder stops that.
                user.ipAddress = "0.0.0.0"
                event.user = user
                event.serverName = nil
                if var app = event.context?["app"] {
                    app["device_app_hash"] = nil
                    event.context?["app"] = app
                }
                return event
            }
            options.beforeBreadcrumb = { breadcrumb in
                for key in breadcrumb.data.map({ Array($0.keys) }) ?? [] {
                    breadcrumb.setData(value: nil, key: key)
                }
                return breadcrumb
            }
        }
    }

    /// Stops reporting until the next `start`.
    public static func stop() {
        guard isRunning else { return }
        SentrySDK.close()
    }

    /// Crashes the app on purpose, to check the setup end to end.
    public static func crash() {
        SentrySDK.crash()
    }
}
