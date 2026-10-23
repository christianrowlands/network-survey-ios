import Foundation
import SurveyCore
import Synchronization

/// The phone's location, except while only demo boards survey: then the
/// simulated walk through the demo board's made-up neighbourhood, so the demo
/// needs no location access and its map lines up with what the board hears.
nonisolated final class SurveyLocationProvider: LocationProvider {
    let phone: CoreLocationProvider
    let demo: SimulatedLocationProvider
    /// Decides at each start whether this session is demo only.
    private let usesDemo: @Sendable () async -> Bool
    private let demoActive = Mutex(false)

    init(phone: CoreLocationProvider, demo: SimulatedLocationProvider, usesDemo: @escaping @Sendable () async -> Bool) {
        self.phone = phone
        self.demo = demo
        self.usesDemo = usesDemo
    }

    func updates() -> AsyncStream<LocationSample> {
        let sources = [phone.updates(), demo.updates()]
        return AsyncStream { continuation in
            let tasks = sources.map { source in
                Task {
                    for await sample in source { continuation.yield(sample) }
                }
            }
            continuation.onTermination = { _ in tasks.forEach { $0.cancel() } }
        }
    }

    func authorization() async -> LocationAuthorization {
        demoActive.withLock { $0 } ? .whenInUse(precise: true) : await phone.authorization()
    }

    func requestAuthorization() async {
        await phone.requestAuthorization()
    }

    func requestTemporaryFullAccuracy() async {
        await phone.requestTemporaryFullAccuracy()
    }

    func start(background: Bool) async {
        let demoOnly = await usesDemo()
        demoActive.withLock { $0 = demoOnly }
        if demoOnly {
            await demo.start(background: background)
        } else {
            await phone.start(background: background)
        }
    }

    func stop() async {
        await phone.stop()
        await demo.stop()
        demoActive.withLock { $0 = false }
    }
}
