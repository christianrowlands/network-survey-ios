import BoardProtocol
import Foundation
import Synchronization

/// 0 to 1 battery level of the phone. The app supplies a UIDevice-backed one.
public protocol BatteryProvider: Sendable {
    func batteryLevel() async -> Double?
}

public struct UnknownBattery: BatteryProvider {
    public init() {}
    public func batteryLevel() async -> Double? { nil }
}

/// Live numbers for the survey screen.
public struct PipelineCounters: Sendable, Equatable {
    /// Records received from boards, by message type.
    public var received: [MessageType: Int] = [:]
    /// Records stored and sent, by message type (device status included).
    public var delivered: [MessageType: Int] = [:]
    /// Dropped by privacy zones or the ignore list.
    public var filtered = 0
    public var rawFrames = 0
    /// Raw frames dropped because storage or destinations fell behind.
    public var rawFramesShed = 0
    public var perBoard: [String: Int] = [:]
    public var lostNotifications = 0
    public var lastRecordAt: Date?
    public var storeErrors = 0

    public init() {}
}

/// Decides which records also get an `observation` row (signal history and
/// map detail). Entity rows are always updated; observations are kept for
/// the first sighting, a new strongest signal, an RSSI change of
/// `rssiDelta` dB, a move of `distance` meters, or every `interval` seconds.
/// This bounds the database to roughly one row per item per interval.
struct ObservationThinner {
    private struct Key: Hashable {
        var kind: UInt8
        var address: Data
        var ssid: Data
    }

    private struct Last {
        var time: Date
        var rssi: Int32
        var best: Int32
        var point: GeoPoint?
    }

    var interval: TimeInterval = 10
    var rssiDelta: Int32 = 3
    var distance: Double = 10
    private var last: [Key: Last] = [:]

    mutating func keep(_ kind: NSBRecord.OneOf_Kind, time: Date, point: GeoPoint?) -> Bool {
        let key: Key, rssi: Int32, rssiMax: Int32
        switch kind {
        case .ap(let r): (key, rssi, rssiMax) = (Key(kind: 0, address: r.bssid, ssid: Data()), r.rssiLast, r.rssiMax)
        case .client(let r): (key, rssi, rssiMax) = (Key(kind: 1, address: r.clientMac, ssid: Data()), r.rssiLast, r.rssiMax)
        case .probe(let r): (key, rssi, rssiMax) = (Key(kind: 2, address: r.clientMac, ssid: r.ssid), r.rssiLast, r.rssiMax)
        case .ble(let r): (key, rssi, rssiMax) = (Key(kind: 3, address: r.address, ssid: Data()), r.rssiLast, r.rssiMax)
        case .gps: return false
        }
        if let previous = last[key] {
            let moved = zip(previous.point, point).map { $0.distance(to: $1) >= distance } ?? (previous.point == nil && point != nil)
            let changed = abs(rssi - previous.rssi) >= rssiDelta || rssiMax > previous.best || moved
                || abs(time.timeIntervalSince(previous.time)) >= interval
            guard changed else { return false }
            last[key] = Last(time: time, rssi: rssi, best: max(previous.best, rssiMax), point: point ?? previous.point)
        } else {
            last[key] = Last(time: time, rssi: rssi, best: rssiMax, point: point)
        }
        return true
    }
}

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}

/// Runs `operation`, giving up waiting after `limit`. The operation keeps
/// running in the background if it does not finish. Returns false on timeout.
@discardableResult
func withTimeout(_ limit: Duration, _ operation: @escaping @Sendable () async -> Void) async -> Bool {
    let pending = Mutex<CheckedContinuation<Bool, Never>?>(nil)
    let finish: @Sendable (Bool) -> Void = { result in
        pending.withLock { continuation in
            continuation?.resume(returning: result)
            continuation = nil
        }
    }
    return await withCheckedContinuation { continuation in
        pending.withLock { $0 = continuation }
        Task {
            await operation()
            finish(true)
        }
        Task {
            try? await Task.sleep(for: limit)
            finish(false)
        }
    }
}
