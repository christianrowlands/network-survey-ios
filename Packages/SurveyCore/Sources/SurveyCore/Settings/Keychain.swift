import Foundation
import Security
import Synchronization

public protocol KeychainStore: Sendable {
    func read(_ name: String) throws -> String?
    func write(_ value: String, for name: String) throws
    func delete(_ name: String) throws
}

public struct KeychainError: Error, Equatable, CustomStringConvertible {
    public let status: OSStatus

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "Keychain error \(status): \(message)"
    }
}

/// Generic passwords in the app's Keychain, readable after the first unlock so
/// a survey keeps working while the phone is locked.
public struct SystemKeychain: KeychainStore {
    public let service: String

    public init(service: String = "app.networksurvey.settings") {
        self.service = service
    }

    public func read(_ name: String) throws -> String? {
        var query = baseQuery(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return (result as? Data).map { String(decoding: $0, as: UTF8.self) }
    }

    public func write(_ value: String, for name: String) throws {
        let data = Data(value.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(baseQuery(name) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(name)
            add.merge(update) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete(_ name: String) throws {
        let status = SecItemDelete(baseQuery(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func baseQuery(_ name: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

public final class InMemoryKeychain: KeychainStore {
    private let items = Mutex<[String: String]>([:])

    public init() {}

    public func read(_ name: String) throws -> String? {
        items.withLock { $0[name] }
    }

    public func write(_ value: String, for name: String) throws {
        items.withLock { $0[name] = value }
    }

    public func delete(_ name: String) throws {
        items.withLock { _ = $0.removeValue(forKey: name) }
    }
}
