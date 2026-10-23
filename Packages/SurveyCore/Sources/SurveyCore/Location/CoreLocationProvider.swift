import CoreLocation
import Foundation

/// Phone location from `CLLocationManager`, configured per the background
/// research: When In Use authorization only, updates never pause, background
/// updates and a `CLBackgroundActivitySession` while a survey runs.
@MainActor
public final class CoreLocationProvider: NSObject, LocationProvider {
    private let manager = CLLocationManager()
    private nonisolated let broadcaster = Broadcaster<LocationSample>()
    private nonisolated let failures = Broadcaster<CLError.Code>()
    /// Fixes older than this when delivered (Core Location's cached first fix) are dropped.
    public nonisolated static let maxFixAge: TimeInterval = 10
    private var authorizationWaiters: [CheckedContinuation<Void, Never>] = []
    #if os(iOS)
    private var backgroundSession: CLBackgroundActivitySession?
    #endif

    /// Purpose key in NSLocationTemporaryUsageDescriptionDictionary.
    public static let fullAccuracyPurposeKey = "SurveyAccuracy"

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        #if os(iOS)
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        #endif
    }

    public nonisolated func updates() -> AsyncStream<LocationSample> {
        broadcaster.stream()
    }

    /// Core Location errors as they happen, so the UI can tell "no fix yet"
    /// (`.locationUnknown`) from "denied" (`.denied`).
    public nonisolated func errors() -> AsyncStream<CLError.Code> {
        failures.stream()
    }

    public func authorization() async -> LocationAuthorization {
        currentAuthorization
    }

    public func requestAuthorization() async {
        guard manager.authorizationStatus == .notDetermined else {
            // While Location Services are off iOS reports `.denied`, and asking
            // shows its "Turn On Location Services" alert, whose Settings button
            // opens that page. The answer comes later as an authorization change.
            if await !Self.servicesEnabled() { manager.requestWhenInUseAuthorization() }
            return
        }
        await withCheckedContinuation { continuation in
            authorizationWaiters.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Asks for precise location for this session when the user turned it off.
    /// Uses the `SurveyAccuracy` purpose string.
    public func requestTemporaryFullAccuracy() async {
        guard manager.accuracyAuthorization == .reducedAccuracy else { return }
        try? await manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: Self.fullAccuracyPurposeKey)
    }

    /// Whether Location Services are on for the whole iPhone. While they are
    /// off, Core Location reports `.denied` for every app, including one that
    /// never asked. The check can block, so it runs off the main thread.
    public nonisolated static func servicesEnabled() async -> Bool {
        await Task.detached(priority: .utility) { CLLocationManager.locationServicesEnabled() }.value
    }

    public func start(background: Bool) async {
        #if os(iOS)
        if background {
            // Must be created while the app is in the foreground (user tapped
            // Start) or right after a relaunch that resumes a running survey.
            if backgroundSession == nil { backgroundSession = CLBackgroundActivitySession() }
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        #endif
        manager.startUpdatingLocation()
    }

    public func stop() async {
        manager.stopUpdatingLocation()
        #if os(iOS)
        manager.allowsBackgroundLocationUpdates = false
        backgroundSession?.invalidate()
        backgroundSession = nil
        #endif
    }

    private var currentAuthorization: LocationAuthorization {
        switch manager.authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        default: .whenInUse(precise: manager.accuracyAuthorization == .fullAccuracy)
        }
    }

    private func authorizationChanged() {
        guard manager.authorizationStatus != .notDetermined else { return }
        let waiters = authorizationWaiters
        authorizationWaiters = []
        waiters.forEach { $0.resume() }
    }

    nonisolated static func sample(from location: CLLocation) -> LocationSample {
        LocationSample(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
            horizontalAccuracy: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
            speed: location.speed >= 0 ? location.speed : nil,
            course: location.course >= 0 ? location.course : nil,
            timestamp: location.timestamp,
            source: .phone
        )
    }
}

extension CoreLocationProvider: CLLocationManagerDelegate {
    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations
        where location.horizontalAccuracy >= 0 && location.timestamp.timeIntervalSinceNow >= -Self.maxFixAge {
            broadcaster.send(Self.sample(from: location))
        }
    }

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { authorizationChanged() }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // .locationUnknown is transient; the manager keeps trying.
        if let error = error as? CLError { failures.send(error.code) }
    }
}
