import BoardKit
import CoreBluetooth
import Observation
import SurveyCore
import UIKit

/// Bluetooth as the app can use it.
enum BluetoothAccess: Equatable {
    /// The app never asked. Asking happens when the user looks for a board.
    case notDetermined
    case denied
    case restricted
    case off
    case unsupported
    /// Allowed and on (or still starting up).
    case ready

    var blocksBoards: Bool {
        switch self {
        case .denied, .restricted, .off, .unsupported: true
        case .notDetermined, .ready: false
        }
    }
}

/// Location as the app can use it. Core Location reports `.denied` both when
/// the user turned location off for this app and when Location Services are off
/// for the whole iPhone. Only the first can be fixed on the app's Settings page,
/// which shows a Location row only after the app has asked.
enum LocationAccess: Equatable {
    /// The app never asked. Asking shows the system prompt.
    case notDetermined
    /// Location Services are off for the whole iPhone.
    case servicesOff
    /// Screen Time or a device management profile blocks location.
    case restricted
    /// The user turned location off for this app.
    case denied
    /// Allowed, with Precise Location off.
    case approximate
    case ready

    init(authorization: LocationAuthorization, servicesEnabled: Bool) {
        if !servicesEnabled {
            self = .servicesOff
            return
        }
        switch authorization {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .whenInUse(let precise): self = precise ? .ready : .approximate
        }
    }

    var isAllowed: Bool {
        self == .ready || self == .approximate
    }

    /// Records from a real board can't get the phone's position.
    var blocksRecords: Bool {
        self == .servicesOff || self == .restricted || self == .denied
    }
}

/// Bluetooth and location access, refreshed while the app is active, for the
/// notices that block a survey and link to Settings.
@MainActor
@Observable
final class AccessModel {
    private(set) var bluetooth = BluetoothAccess.notDetermined
    private(set) var location = LocationAccess.notDetermined

    /// Reads the Bluetooth power state, once the Bluetooth transport exists.
    @ObservationIgnored var powerState: (() -> BLEPowerState)?
    @ObservationIgnored private let locationProvider: any LocationProvider
    @ObservationIgnored private let servicesEnabled: @Sendable () async -> Bool

    init(
        locationProvider: any LocationProvider,
        servicesEnabled: @escaping @Sendable () async -> Bool = CoreLocationProvider.servicesEnabled
    ) {
        self.locationProvider = locationProvider
        self.servicesEnabled = servicesEnabled
    }

    func refresh() async {
        let authorization = await locationProvider.authorization()
        location = LocationAccess(authorization: authorization, servicesEnabled: await servicesEnabled())
        bluetooth = Self.bluetoothAccess(authorization: CBManager.authorization, power: powerState?())
    }

    /// Runs a location notice's action, then reads access again.
    func perform(_ action: LocationNotice.Action) async {
        switch action {
        case .allow, .turnOnServices: await locationProvider.requestAuthorization()
        case .usePrecise: await locationProvider.requestTemporaryFullAccuracy()
        case .openSettings: Self.openAppSettings()
        }
        await refresh()
    }

    static func bluetoothAccess(authorization: CBManagerAuthorization, power: BLEPowerState?) -> BluetoothAccess {
        switch authorization {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        default: break
        }
        switch power {
        case .poweredOff: return .off
        case .unsupported: return .unsupported
        case .unauthorized: return .denied
        default: return .ready
        }
    }

    /// The app's page in Settings, where Bluetooth and Location access are switched.
    static func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
