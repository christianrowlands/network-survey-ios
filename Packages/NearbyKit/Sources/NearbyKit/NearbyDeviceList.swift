import Foundation

/// A signal reading for the detail chart.
public struct NearbyReading: Sendable, Equatable {
    public var time: Date
    public var rssi: Int

    public init(time: Date, rssi: Int) {
        self.time = time
        self.rssi = rssi
    }
}

/// One peripheral as this iPhone has heard it since the list opened. A device
/// that changes its address appears again as a new device: iOS gives no way to
/// tell.
public struct NearbyDevice: Sendable, Identifiable, Equatable {
    /// CoreBluetooth's identifier, only meaningful on this iPhone. Never shown.
    public let id: UUID
    public var name: String?
    public var manufacturerData: Data?
    public var serviceUUIDs: [String]
    public var serviceDataUUIDs: [String]
    public var txPower: Int?
    public var isConnectable: Bool?
    public var rssi: Int
    public var firstHeard: Date
    public var lastHeard: Date
    /// Readings from the last `NearbyDeviceList.historyWindow` seconds.
    public var history: [NearbyReading]

    public var companyID: Int? {
        NearbyAdvertisement.companyID(manufacturerData)
    }
}

public enum NearbySort: String, Sendable, CaseIterable {
    case signal
    case recent
}

/// The devices heard so far, in memory only. Bounded so a long session in a
/// busy place cannot grow without limit.
public struct NearbyDeviceList: Sendable {
    public static let defaultCapacity = 2_000
    public static let historyWindow: TimeInterval = 120
    /// A device not heard for this long sorts after the ones heard lately:
    /// its last signal no longer says how close it is.
    public static let recentWindow: TimeInterval = 30
    /// One reading per half second at most, so a fast advertiser still fills
    /// the whole window: 120 s at 0.5 s is `maxReadings`.
    static let readingInterval: TimeInterval = 0.5
    static let maxReadings = 240

    public private(set) var devices: [UUID: NearbyDevice] = [:]
    public private(set) var hidden: Set<UUID> = []
    let capacity: Int

    public init(capacity: Int = NearbyDeviceList.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { devices.count }

    public subscript(id: UUID) -> NearbyDevice? { devices[id] }

    public mutating func record(_ ad: NearbyAdvertisement) {
        // CoreBluetooth reports 127 when it has no RSSI.
        guard !hidden.contains(ad.peripheralID), ad.rssi < 127 else { return }
        let reading = NearbyReading(time: ad.time, rssi: ad.rssi)
        guard var device = devices.removeValue(forKey: ad.peripheralID) else {
            if devices.count >= capacity { evictOldest() }
            devices[ad.peripheralID] = NearbyDevice(
                id: ad.peripheralID, name: Self.name(ad.localName), manufacturerData: ad.manufacturerData,
                serviceUUIDs: ad.serviceUUIDs, serviceDataUUIDs: ad.serviceDataUUIDs, txPower: ad.txPower,
                isConnectable: ad.isConnectable, rssi: ad.rssi, firstHeard: ad.time, lastHeard: ad.time,
                history: [reading]
            )
            return
        }
        // Names, services and manufacturer data can arrive in separate
        // advertisements (the scan response), so keep the last known values.
        if let name = Self.name(ad.localName) { device.name = name }
        if let data = ad.manufacturerData { device.manufacturerData = data }
        if !ad.serviceUUIDs.isEmpty { device.serviceUUIDs = ad.serviceUUIDs }
        if !ad.serviceDataUUIDs.isEmpty { device.serviceDataUUIDs = ad.serviceDataUUIDs }
        if let txPower = ad.txPower { device.txPower = txPower }
        if let connectable = ad.isConnectable { device.isConnectable = connectable }
        device.rssi = ad.rssi
        device.lastHeard = max(device.lastHeard, ad.time)
        if let last = device.history.last, Self.slot(last.time) == Self.slot(reading.time) {
            device.history[device.history.count - 1] = reading
        } else {
            device.history.append(reading)
        }
        let cutoff = ad.time.addingTimeInterval(-Self.historyWindow)
        device.history.removeAll { $0.time < cutoff }
        if device.history.count > Self.maxReadings {
            device.history.removeFirst(device.history.count - Self.maxReadings)
        }
        devices[ad.peripheralID] = device
    }

    /// Hides a device until the list is cleared.
    public mutating func hide(_ id: UUID) {
        hidden.insert(id)
        devices[id] = nil
    }

    public mutating func removeAll() {
        devices.removeAll()
        hidden.removeAll()
    }

    /// Strongest of the recently heard first, or most recently heard first.
    public func sorted(by sort: NearbySort, now: Date = Date()) -> [NearbyDevice] {
        let recent = now.addingTimeInterval(-Self.recentWindow)
        return devices.values.sorted { a, b in
            switch sort {
            case .signal:
                let aRecent = a.lastHeard >= recent, bRecent = b.lastHeard >= recent
                if aRecent != bRecent { return aRecent }
                if a.rssi != b.rssi { return a.rssi > b.rssi }
                if a.lastHeard != b.lastHeard { return a.lastHeard > b.lastHeard }
            case .recent:
                if a.lastHeard != b.lastHeard { return a.lastHeard > b.lastHeard }
                if a.rssi != b.rssi { return a.rssi > b.rssi }
            }
            return a.id.uuidString < b.id.uuidString
        }
    }

    private static func slot(_ time: Date) -> Int {
        Int((time.timeIntervalSince1970 / readingInterval).rounded(.down))
    }

    private mutating func evictOldest() {
        guard let oldest = devices.values.min(by: { $0.lastHeard < $1.lastHeard }) else { return }
        devices[oldest.id] = nil
    }

    private static func name(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
