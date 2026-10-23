import Foundation
import Synchronization

/// What this phone has learned from verified release manifests, so a stale or
/// replayed manifest (an old but validly signed release) is noticed.
public struct FirmwareReleaseRecord: Codable, Equatable, Sendable {
    /// Highest release version verified so far.
    public var highestVersion: String?
    /// Highest `min_version` seen: releases below it are refused.
    public var minimumVersion: String?

    public init(highestVersion: String? = nil, minimumVersion: String? = nil) {
        self.highestVersion = highestVersion
        self.minimumVersion = minimumVersion
    }

    /// Folds in a verified manifest's version and minimum.
    func merging(version: String, minimum: String?) -> FirmwareReleaseRecord {
        FirmwareReleaseRecord(
            highestVersion: Self.higher(highestVersion, version),
            minimumVersion: Self.higher(minimumVersion, minimum)
        )
    }

    static func higher(_ a: String?, _ b: String?) -> String? {
        guard let a, let parsedA = FirmwareVersion(a) else { return b.flatMap { FirmwareVersion($0) == nil ? nil : $0 } }
        guard let b, let parsedB = FirmwareVersion(b) else { return a }
        return parsedB > parsedA ? b : a
    }
}

public protocol FirmwareReleaseHistory: Sendable {
    func load() -> FirmwareReleaseRecord
    func save(_ record: FirmwareReleaseRecord)
}

public final class UserDefaultsFirmwareReleaseHistory: FirmwareReleaseHistory, @unchecked Sendable {
    // UserDefaults is thread safe; the key is fixed.
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "firmwareReleaseHistory") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> FirmwareReleaseRecord {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(FirmwareReleaseRecord.self, from: $0) }
            ?? FirmwareReleaseRecord()
    }

    public func save(_ record: FirmwareReleaseRecord) {
        defaults.set(try? JSONEncoder().encode(record), forKey: key)
    }
}

public final class InMemoryFirmwareReleaseHistory: FirmwareReleaseHistory {
    private let record: Mutex<FirmwareReleaseRecord>

    public init(_ record: FirmwareReleaseRecord = FirmwareReleaseRecord()) {
        self.record = Mutex(record)
    }

    public func load() -> FirmwareReleaseRecord { record.withLock { $0 } }
    public func save(_ record: FirmwareReleaseRecord) { self.record.withLock { $0 = record } }
}
