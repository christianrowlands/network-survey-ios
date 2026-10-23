import Foundation

public enum LocationAuthorization: Sendable, Equatable {
    case notDetermined
    case denied
    case restricted
    /// When In Use; `precise` is false when the user turned off Precise Location.
    case whenInUse(precise: Bool)
}

/// The phone's position. `CoreLocationProvider` in the app,
/// `SimulatedLocationProvider` for tests and the demo board.
public protocol LocationProvider: AnyObject, Sendable {
    /// Every fix as it arrives. Each call returns a new subscriber stream.
    func updates() -> AsyncStream<LocationSample>
    func authorization() async -> LocationAuthorization
    /// Asks for When In Use authorization if it was never asked, or for
    /// Location Services to be turned on when they are off.
    func requestAuthorization() async
    /// Asks for precise location until the app is no longer in use, when the
    /// user allowed only approximate location.
    func requestTemporaryFullAccuracy() async
    /// Starts continuous updates. With `background`, updates keep coming while
    /// the app is in the background (a survey is running).
    func start(background: Bool) async
    func stop() async
}

/// Picks the position that stamps a record.
///
/// With `.phone` (the default) the phone fix is used when it is fresh and
/// accurate enough; otherwise a fresh board GPS fix; otherwise a fresh but
/// inaccurate phone fix. With `.board` a fresh board fix wins and the phone is
/// the fallback. Fixes older than `maxAge` are never used.
public struct LocationSourcePolicy: Sendable, Equatable {
    public var preference: LocationSourcePreference
    public var maxAge: TimeInterval
    /// A phone fix worse than this (meters) yields to a fresh board fix.
    public var phoneAccuracyLimit: Double

    public init(preference: LocationSourcePreference = .phone, maxAge: TimeInterval = 10, phoneAccuracyLimit: Double = 50) {
        self.preference = preference
        self.maxAge = maxAge
        self.phoneAccuracyLimit = phoneAccuracyLimit
    }

    public func choose(phone: LocationSample?, board: LocationSample?, at now: Date) -> LocationSample? {
        let phone = phone.flatMap { isFresh($0, at: now) ? $0 : nil }
        let board = board.flatMap { isFresh($0, at: now) ? $0 : nil }
        switch preference {
        case .board:
            return board ?? phone
        case .phone:
            if let phone, (phone.horizontalAccuracy ?? 0) <= phoneAccuracyLimit { return phone }
            return board ?? phone
        }
    }

    private func isFresh(_ sample: LocationSample, at now: Date) -> Bool {
        abs(now.timeIntervalSince(sample.timestamp)) <= maxAge
    }
}
