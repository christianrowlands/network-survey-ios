import BoardKit
import Foundation
import Synchronization

/// A phone that walks the simulated board world's survey loop, one fix per
/// second. Used by tests and by the demo board so positions match the RSSI the
/// simulated boards report.
public final class SimulatedLocationProvider: LocationProvider {
    public enum TimeSource: Sendable, Equatable {
        case realtime(speed: Double)
        /// Fixes are produced only by `advance(bySeconds:)`.
        case manual
    }

    private struct State {
        var running = false
        var elapsedSeconds = 0
        var authorization = LocationAuthorization.whenInUse(precise: true)
        var clock: Task<Void, Never>?
        /// When second 0 of the walk was, for fix timestamps. Realtime walks move
        /// it at each start, so fixes carry the current time however long the
        /// app waited before the survey (stale fixes are thrown away).
        var timeBase: Date
    }

    /// Where the simulated area's (0, 0) corner sits. The area spans about
    /// 200 m east by 120 m north from here.
    public let origin: GeoPoint
    public let startDate: Date
    public let horizontalAccuracy: Double
    private let timeSource: TimeSource
    private let broadcaster = Broadcaster<LocationSample>()
    private let state: Mutex<State>

    public init(
        origin: GeoPoint = GeoPoint(latitude: 38.8895, longitude: -77.0353),
        startDate: Date = Date(), timeSource: TimeSource = .realtime(speed: 1), horizontalAccuracy: Double = 5
    ) {
        self.origin = origin
        self.startDate = startDate
        self.timeSource = timeSource
        self.horizontalAccuracy = horizontalAccuracy
        state = Mutex(State(timeBase: startDate))
    }

    public func updates() -> AsyncStream<LocationSample> {
        broadcaster.stream()
    }

    public func authorization() async -> LocationAuthorization {
        state.withLock { $0.authorization }
    }

    /// Simulates the user allowing location when asked.
    public func requestAuthorization() async {
        state.withLock { if $0.authorization == .notDetermined { $0.authorization = .whenInUse(precise: true) } }
    }

    /// Simulates the user allowing precise location when asked.
    public func requestTemporaryFullAccuracy() async {
        state.withLock { if $0.authorization == .whenInUse(precise: false) { $0.authorization = .whenInUse(precise: true) } }
    }

    /// Simulates the user changing authorization in Settings.
    public func setAuthorization(_ authorization: LocationAuthorization) {
        state.withLock { $0.authorization = authorization }
    }

    public func start(background: Bool) async {
        let startClock = state.withLock { state -> Bool in
            guard !state.running else { return false }
            state.running = true
            if timeSource != .manual {
                state.timeBase = Date().addingTimeInterval(-Double(state.elapsedSeconds))
            }
            return state.clock == nil
        }
        guard startClock, case .realtime(let speed) = timeSource else { return }
        let interval = Duration.milliseconds(1000 / max(speed, 0.01))
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                self?.advance(bySeconds: 1)
            }
        }
        state.withLock { $0.clock = task }
    }

    public func stop() async {
        let clock = state.withLock { state -> Task<Void, Never>? in
            state.running = false
            defer { state.clock = nil }
            return state.clock
        }
        clock?.cancel()
    }

    /// Moves time forward, emitting one fix per second while running.
    public func advance(bySeconds seconds: Int) {
        for _ in 0..<max(seconds, 0) {
            let elapsed = state.withLock { state -> Int? in
                state.elapsedSeconds += 1
                return state.running ? state.elapsedSeconds : nil
            }
            if let elapsed { broadcaster.send(sample(atSeconds: elapsed)) }
        }
    }

    /// The fix the walk gives `seconds` after `startDate`.
    public func sample(atSeconds seconds: Int) -> LocationSample {
        let point = SimulatedWorld.surveyorPosition(atMs: UInt64(seconds) * 1000)
        let next = SimulatedWorld.surveyorPosition(atMs: UInt64(seconds + 1) * 1000)
        let dx = next.x - point.x, dy = next.y - point.y
        var course = atan2(dx, dy) * 180 / .pi
        if course < 0 { course += 360 }
        return LocationSample(
            latitude: origin.latitude + point.y / Self.metersPerDegreeLatitude,
            longitude: origin.longitude + point.x / metersPerDegreeLongitude,
            altitude: 20,
            horizontalAccuracy: horizontalAccuracy,
            speed: (dx * dx + dy * dy).squareRoot(),
            course: course,
            timestamp: state.withLock { $0.timeBase }.addingTimeInterval(TimeInterval(seconds)),
            source: .phone
        )
    }

    static let metersPerDegreeLatitude = 111_320.0

    private var metersPerDegreeLongitude: Double {
        Self.metersPerDegreeLatitude * cos(origin.latitude * .pi / 180)
    }
}
