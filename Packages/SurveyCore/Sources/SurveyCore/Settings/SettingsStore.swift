import Foundation
import Synchronization

/// Where plain settings live. `UserDefaults` in the app, a dictionary in tests.
public protocol SettingsBackend: Sendable {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

/// UserDefaults is documented as thread safe.
public struct UserDefaultsBackend: SettingsBackend, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(_ defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func object(forKey key: String) -> Any? {
        defaults.object(forKey: key)
    }

    public func set(_ value: Any?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

public final class InMemorySettingsBackend: SettingsBackend {
    /// Stored values are plist types (numbers, strings), which are immutable.
    private struct Box: @unchecked Sendable {
        let value: Any
    }

    private let values = Mutex<[String: Box]>([:])

    public init() {}

    public func object(forKey key: String) -> Any? {
        values.withLock { $0[key]?.value }
    }

    public func set(_ value: Any?, forKey key: String) {
        let box = value.map(Box.init)
        values.withLock { $0[key] = box }
    }
}

/// The one place settings and secrets are read and written.
///
/// Values that were never set read as the key's default. Writing the default
/// stores it explicitly; `reset` removes the stored value. Every change is
/// announced on `changes()` by key name.
public final class SettingsStore: Sendable {
    private let backend: any SettingsBackend
    private let keychain: any KeychainStore
    private let changeContinuations = Mutex<[UUID: AsyncStream<String>.Continuation]>([:])

    public init(backend: any SettingsBackend = UserDefaultsBackend(), keychain: any KeychainStore = SystemKeychain()) {
        self.backend = backend
        self.keychain = keychain
    }

    /// A store with no persistence, for tests and previews.
    public static func inMemory() -> SettingsStore {
        SettingsStore(backend: InMemorySettingsBackend(), keychain: InMemoryKeychain())
    }

    public subscript<Value>(key: SettingKey<Value>) -> Value {
        get { backend.object(forKey: key.name).flatMap(key.decode) ?? key.defaultValue }
        set {
            backend.set(key.encode(newValue), forKey: key.name)
            announce(key.name)
        }
    }

    public func reset<Value>(_ key: SettingKey<Value>) {
        backend.set(nil, forKey: key.name)
        announce(key.name)
    }

    /// The secret, or nil when it is missing or the Keychain cannot be read.
    public func secret(_ key: SecretKey) -> String? {
        try? keychain.read(key.name)
    }

    /// The secret; nil only when it does not exist. Throws when the Keychain
    /// cannot be read (for example locked before first unlock).
    public func readSecret(_ key: SecretKey) throws -> String? {
        try keychain.read(key.name)
    }

    /// Keychain items survive app deletion. On the first launch of a fresh
    /// install (no marker in defaults) the old credentials are deleted; the
    /// install ID is kept so the device keeps its identity. Returns true when
    /// this was a fresh install.
    @discardableResult
    public func clearStaleCredentialsOnFreshInstall() -> Bool {
        let marker = "install_marker"
        guard backend.object(forKey: marker) == nil else { return false }
        for key in Secrets.credentials { try? keychain.delete(key.name) }
        backend.set(true, forKey: marker)
        return true
    }

    public func setSecret(_ value: String?, for key: SecretKey) throws {
        if let value, !value.isEmpty {
            try keychain.write(value, for: key.name)
        } else {
            try keychain.delete(key.name)
        }
        announce(key.name)
    }

    /// Names of keys as they change.
    public func changes() -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(64))
        let id = UUID()
        changeContinuations.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.changeContinuations.withLock { _ = $0.removeValue(forKey: id) }
        }
        return stream
    }

    private func announce(_ name: String) {
        // Yield outside the lock: a cancelled subscriber's termination handler
        // takes it while the stream holds its own lock.
        let continuations = changeContinuations.withLock { Array($0.values) }
        for continuation in continuations { continuation.yield(name) }
    }
}
