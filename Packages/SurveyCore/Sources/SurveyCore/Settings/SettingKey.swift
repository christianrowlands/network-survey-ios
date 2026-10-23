import Foundation

/// A typed setting. `name` is the stored key and is also the key a future
/// managed configuration (AppConfig) layer would use to override the value, so
/// names are stable, snake_case and follow the Network Survey Android app's
/// managed configuration keys where one exists. See docs/settings-keys.md.
public struct SettingKey<Value: Sendable>: Sendable {
    public let name: String
    public let defaultValue: Value
    let decode: @Sendable (Any) -> Value?
    let encode: @Sendable (Value) -> Any

    public init(
        _ name: String, default defaultValue: Value,
        decode: @escaping @Sendable (Any) -> Value?, encode: @escaping @Sendable (Value) -> Any
    ) {
        self.name = name
        self.defaultValue = defaultValue
        self.decode = decode
        self.encode = encode
    }
}

// Decoders are lenient: a managed configuration dictionary may deliver
// numbers and booleans as strings ("8883", "true").

extension SettingKey where Value == Bool {
    public init(_ name: String, default defaultValue: Bool) {
        self.init(name, default: defaultValue, decode: SettingDecoding.bool, encode: { $0 })
    }
}

extension SettingKey where Value == Int {
    /// Values outside `range` read as the default.
    public init(_ name: String, default defaultValue: Int, range: ClosedRange<Int>? = nil) {
        self.init(
            name, default: defaultValue,
            decode: { raw in
                guard let value = SettingDecoding.int(raw) else { return nil }
                return range.map { $0.contains(value) } ?? true ? value : nil
            },
            encode: { $0 }
        )
    }
}

enum SettingDecoding {
    @Sendable static func bool(_ raw: Any) -> Bool? {
        if let value = raw as? Bool { return value }
        if let number = raw as? NSNumber { return number.boolValue }
        switch (raw as? String)?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }

    @Sendable static func int(_ raw: Any) -> Int? {
        if let number = raw as? NSNumber { return number.intValue }
        return (raw as? String).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }
}

extension SettingKey where Value == Double {
    public init(_ name: String, default defaultValue: Double) {
        self.init(name, default: defaultValue, decode: { ($0 as? NSNumber)?.doubleValue }, encode: { $0 })
    }
}

extension SettingKey where Value == String {
    public init(_ name: String, default defaultValue: String) {
        self.init(name, default: defaultValue, decode: { $0 as? String }, encode: { $0 })
    }
}

extension SettingKey {
    /// A string-backed enum. Unknown stored strings read as the default.
    public static func enumeration(_ name: String, default defaultValue: Value) -> SettingKey
    where Value: RawRepresentable, Value.RawValue == String {
        SettingKey(
            name, default: defaultValue,
            decode: { ($0 as? String).flatMap(Value.init(rawValue:)) },
            encode: { $0.rawValue }
        )
    }

    /// A Codable value stored as JSON text, for lists such as privacy zones.
    public static func json(_ name: String, default defaultValue: Value) -> SettingKey where Value: Codable {
        SettingKey(
            name, default: defaultValue,
            decode: { raw in
                guard let text = raw as? String else { return nil }
                return try? JSONDecoder().decode(Value.self, from: Data(text.utf8))
            },
            encode: { value in
                let data = (try? JSONEncoder().encode(value)) ?? Data()
                return String(decoding: data, as: UTF8.self)
            }
        )
    }
}

/// A secret kept in the Keychain rather than in defaults.
public struct SecretKey: Hashable, Sendable {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }
}
