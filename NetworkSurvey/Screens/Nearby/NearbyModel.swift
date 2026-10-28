import Foundation
import NearbyKit
import Observation

/// Nearby Bluetooth while its screen is open: what this iPhone's own radio
/// hears, in memory only. Created when the screen opens and dropped when it
/// closes, so nothing outlives the screen. It never touches the survey.
@MainActor
@Observable
final class NearbyModel {
    private(set) var radio = NearbyRadioState.unknown
    /// Read again on every radio change: the Bluetooth prompt's answer arrives that way.
    private(set) var authorization: NearbyAuthorization
    private(set) var devices: [NearbyDevice] = []
    private(set) var isLooking = false
    /// Looking stopped because the app went to the background.
    private(set) var pausedByBackground = false
    /// When the current look started, for the "nothing heard yet" hint.
    private(set) var lookingSince: Date?
    var sort = NearbySort.signal {
        didSet { publish() }
    }

    @ObservationIgnored private let scanner: any NearbyScanner
    @ObservationIgnored private var list = NearbyDeviceList()
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    init(scanner: any NearbyScanner) {
        self.scanner = scanner
        authorization = scanner.authorization
    }

    func device(_ id: UUID) -> NearbyDevice? {
        list[id]
    }

    /// Starts or resumes listening. The first time, iOS may ask for Bluetooth.
    func look() {
        if tasks.isEmpty {
            tasks.append(Task { [weak self, scanner] in
                for await event in scanner.events() {
                    self?.handle(event)
                }
            })
            // The list changes many times a second; the screen redraws once a second.
            tasks.append(Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self else { return }
                    self.refreshRadio()
                    if self.isLooking { self.publish() }
                }
            })
        }
        isLooking = true
        pausedByBackground = false
        lookingSince = Date()
        scanner.start()
    }

    func pause() {
        scanner.stop()
        isLooking = false
        lookingSince = nil
        publish()
    }

    /// iOS only lets an app look for nearby devices while it is open.
    func enteredBackground() {
        guard isLooking else { return }
        pause()
        pausedByBackground = true
    }

    func hide(_ id: UUID) {
        list.hide(id)
        publish()
    }

    /// Stops listening and forgets everything heard.
    func close() {
        scanner.stop()
        tasks.forEach { $0.cancel() }
        tasks = []
        isLooking = false
        list.removeAll()
        devices = []
    }

    private func handle(_ event: NearbyScannerEvent) {
        switch event {
        case .state(let state):
            radio = state
            authorization = scanner.authorization
        case .advertisement(let advertisement):
            guard isLooking else { return }
            list.record(advertisement)
            // A first device shows at once instead of on the next redraw.
            if devices.isEmpty { publish() }
        }
    }

    /// The stream may drop events when it backs up, so the state is also read directly.
    private func refreshRadio() {
        let now = scanner.radio
        if now != .unknown && now != radio { radio = now }
        let access = scanner.authorization
        if access != authorization { authorization = access }
    }

    private func publish() {
        devices = list.sorted(by: sort)
    }
}
