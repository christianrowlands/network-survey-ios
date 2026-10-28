import Foundation
import Synchronization

/// Made-up nearby devices for UI tests, screenshots and the simulator, which
/// has no Bluetooth. Deterministic for a seed.
public final class SimulatedNearbyScanner: NearbyScanner, Sendable {
    struct Profile: Sendable {
        var id: UUID
        var name: String?
        var manufacturerData: Data?
        var serviceUUIDs: [String] = []
        var serviceDataUUIDs: [String] = []
        var txPower: Int?
        var connectable: Bool
        var baseRSSI: Int
        /// Share of ticks the device is heard on, 0 to 1.
        var presence: Double
    }

    let profiles: [Profile]
    private let seed: UInt64
    private let interval: Duration
    private let stream: AsyncStream<NearbyScannerEvent>
    private let continuation: AsyncStream<NearbyScannerEvent>.Continuation
    private let task = Mutex<Task<Void, Never>?>(nil)

    public init(seed: UInt64 = 1, interval: Duration = .milliseconds(250)) {
        self.seed = seed
        self.interval = interval
        profiles = Self.makeProfiles(seed: seed)
        (stream, continuation) = AsyncStream.makeStream(of: NearbyScannerEvent.self, bufferingPolicy: .bufferingNewest(1_000))
    }

    deinit {
        task.withLock { $0?.cancel() }
        continuation.finish()
    }

    public var authorization: NearbyAuthorization { .allowed }

    public var radio: NearbyRadioState {
        task.withLock { $0 == nil ? .unknown : .poweredOn }
    }

    public func events() -> AsyncStream<NearbyScannerEvent> { stream }

    public func start() {
        task.withLock { task in
            guard task == nil else { return }
            continuation.yield(.state(.poweredOn))
            task = Task { [profiles, seed, interval, continuation] in
                var random = SplitMix64(seed: seed)
                while !Task.isCancelled {
                    for profile in profiles where random.unit() < profile.presence {
                        let jitter = Int(random.unit() * 9) - 4
                        continuation.yield(.advertisement(NearbyAdvertisement(
                            peripheralID: profile.id, time: Date(), rssi: profile.baseRSSI + jitter,
                            localName: profile.name, manufacturerData: profile.manufacturerData,
                            serviceUUIDs: profile.serviceUUIDs, serviceDataUUIDs: profile.serviceDataUUIDs,
                            txPower: profile.txPower, isConnectable: profile.connectable
                        )))
                    }
                    try? await Task.sleep(for: interval)
                }
            }
        }
    }

    public func stop() {
        task.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    static func makeProfiles(seed: UInt64) -> [Profile] {
        var random = SplitMix64(seed: seed &+ 0x5EED)
        func id() -> UUID {
            let a = random.next(), b = random.next()
            let bytes = (0..<8).map { UInt8(truncatingIfNeeded: a >> ($0 * 8)) } + (0..<8).map { UInt8(truncatingIfNeeded: b >> ($0 * 8)) }
            return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        }
        return [
            Profile(id: id(), name: "Demo Speaker", manufacturerData: Data([0x75, 0x00, 0x42, 0x04, 0x01, 0x20]),
                    txPower: 8, connectable: true, baseRSSI: -54, presence: 0.9),
            Profile(id: id(), name: nil, manufacturerData: Data([0x4C, 0x00, 0x10, 0x05, 0x01, 0x18, 0x00, 0x00, 0x00]),
                    connectable: true, baseRSSI: -63, presence: 0.8),
            Profile(id: id(), name: "Demo Thermometer", serviceDataUUIDs: ["181A"],
                    connectable: false, baseRSSI: -71, presence: 0.5),
            Profile(id: id(), name: "Demo Headphones", serviceUUIDs: ["FE2C"],
                    connectable: true, baseRSSI: -67, presence: 0.6),
            Profile(id: id(), name: nil, manufacturerData: Data([0x06, 0x00, 0x01, 0x09, 0x20, 0x02]),
                    connectable: false, baseRSSI: -78, presence: 0.4),
            Profile(id: id(), name: "Demo Lock", serviceUUIDs: ["180F"], txPower: 0,
                    connectable: true, baseRSSI: -82, presence: 0.3),
            Profile(id: id(), name: nil, manufacturerData: Data([0x4C, 0x00, 0x12, 0x02, 0x00, 0x03]),
                    connectable: false, baseRSSI: -86, presence: 0.3),
        ]
    }
}

/// A small seeded generator, so simulated data repeats exactly.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in 0..<1.
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
