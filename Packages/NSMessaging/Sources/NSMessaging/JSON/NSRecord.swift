import Foundation

/// An NS Messaging message: the `version`, `messageType`, `data` envelope.
public struct NSRecord<Payload: NSRecordData>: Sendable, Equatable, Codable {
    public var version: String
    public var messageType: String
    public var data: Payload

    public init(data: Payload, version: String = NSMessaging.apiVersion) {
        self.version = version
        self.messageType = Payload.messageType
        self.data = data
    }

    /// The JSON the Network Survey Android app would send for this message.
    public func jsonString() -> String {
        var writer = NSJSONWriter()
        writer.beginObject()
        if !version.isEmpty {
            writer.key("version")
            writer.string(version)
        }
        if !messageType.isEmpty {
            writer.key("messageType")
            writer.string(messageType)
        }
        writer.key("data")
        data.write(to: &writer)
        writer.endObject()
        return writer.output
    }

    public func jsonData() -> Data {
        Data(jsonString().utf8)
    }

    /// Parses NS Messaging JSON. Unknown fields are ignored, as are enum names
    /// this version does not know (they become UNKNOWN).
    public init(jsonData: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: jsonData)
    }
}

/// An NS Messaging message body. `fields` lists the JSON fields in proto
/// field-number order, which is the order the Android app writes them.
public protocol NSMessageData: Sendable, Equatable, Codable {
    static var fields: [NSField<Self>] { get }
    init()
}

/// The payload of an NS Messaging message.
public protocol NSRecordData: NSMessageData {
    static var messageType: String { get }
}

extension NSMessageData {
    public func write(to writer: inout NSJSONWriter) {
        writer.beginObject()
        for field in Self.fields { field.write(self, &writer) }
        writer.endObject()
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: NSJSONKey.self)
        for field in Self.fields { try field.decode(&self, container) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: NSJSONKey.self)
        for field in Self.fields { try field.encode(self, &container) }
    }
}

public struct NSJSONKey: CodingKey {
    public var stringValue: String
    public var intValue: Int? { nil }
    public init(_ name: String) { stringValue = name }
    public init?(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) { nil }
}

/// One JSON field of an NS Messaging payload. Plain proto3 fields are left out
/// when they hold their default value; wrapper fields (Optionals here) are left
/// out only when nil.
public struct NSField<Root> {
    public let number: Int
    public let name: String
    let write: (Root, inout NSJSONWriter) -> Void
    let decode: (inout Root, KeyedDecodingContainer<NSJSONKey>) throws -> Void
    let encode: (Root, inout KeyedEncodingContainer<NSJSONKey>) throws -> Void

    private static func make<Value: Codable>(
        _ number: Int, _ name: String, _ path: WritableKeyPath<Root, Value>,
        isDefault: @escaping (Value) -> Bool, write: @escaping (Value, inout NSJSONWriter) -> Void
    ) -> NSField {
        let key = NSJSONKey(name)
        return NSField(
            number: number, name: name,
            write: { root, writer in
                let value = root[keyPath: path]
                guard !isDefault(value) else { return }
                writer.key(name)
                write(value, &writer)
            },
            decode: { root, container in
                if let value = try container.decodeIfPresent(Value.self, forKey: key) { root[keyPath: path] = value }
            },
            encode: { root, container in
                let value = root[keyPath: path]
                if !isDefault(value) { try container.encode(value, forKey: key) }
            }
        )
    }

    public static func string(_ number: Int, _ name: String, _ path: WritableKeyPath<Root, String>) -> NSField {
        make(number, name, path, isDefault: { $0.isEmpty }, write: { $1.string($0) })
    }

    public static func double(_ number: Int, _ name: String, _ path: WritableKeyPath<Root, Double>) -> NSField {
        make(number, name, path, isDefault: { $0.bitPattern == 0 }, write: { $1.double($0) })
    }

    public static func float(_ number: Int, _ name: String, _ path: WritableKeyPath<Root, Float>) -> NSField {
        make(number, name, path, isDefault: { $0.bitPattern == 0 }, write: { $1.float($0) })
    }

    public static func int32(_ number: Int, _ name: String, _ path: WritableKeyPath<Root, Int32>) -> NSField {
        make(number, name, path, isDefault: { $0 == 0 }, write: { $1.integer($0) })
    }

    public static func uint32(_ number: Int, _ name: String, _ path: WritableKeyPath<Root, UInt32>) -> NSField {
        make(number, name, path, isDefault: { $0 == 0 }, write: { $1.integer($0) })
    }

    public static func int32Value(_ number: Int, _ name: String, _ path: WritableKeyPath<Root, Int32?>) -> NSField {
        make(number, name, path, isDefault: { $0 == nil }, write: { $1.integer($0!) })
    }

    public static func floatValue(_ number: Int, _ name: String, _ path: WritableKeyPath<Root, Float?>) -> NSField {
        make(number, name, path, isDefault: { $0 == nil }, write: { $1.float($0!) })
    }

    public static func boolValue(_ number: Int, _ name: String, _ path: WritableKeyPath<Root, Bool?>) -> NSField {
        make(number, name, path, isDefault: { $0 == nil }, write: { $1.bool($0!) })
    }

    /// A proto3 uint64, which JSON carries as a string ("42").
    public static func uint64(_ number: Int, _ name: String, _ path: WritableKeyPath<Root, UInt64>) -> NSField {
        let key = NSJSONKey(name)
        return NSField(
            number: number, name: name,
            write: { root, writer in
                let value = root[keyPath: path]
                guard value != 0 else { return }
                writer.key(name)
                writer.string(String(value))
            },
            decode: { root, container in
                if let text = try? container.decodeIfPresent(String.self, forKey: key), let value = UInt64(text) {
                    root[keyPath: path] = value
                } else if let value = try? container.decodeIfPresent(UInt64.self, forKey: key) {
                    root[keyPath: path] = value
                }
            },
            encode: { root, container in
                let value = root[keyPath: path]
                if value != 0 { try container.encode(String(value), forKey: key) }
            }
        )
    }

    /// A `google.protobuf.StringValue`: left out only when nil, so "" is sent.
    public static func stringValue(_ number: Int, _ name: String, _ path: WritableKeyPath<Root, String?>) -> NSField {
        make(number, name, path, isDefault: { $0 == nil }, write: { $1.string($0!) })
    }

    /// A repeated nested message, left out when empty.
    public static func messageList<Element: NSMessageData>(
        _ number: Int, _ name: String, _ path: WritableKeyPath<Root, [Element]>
    ) -> NSField {
        make(number, name, path, isDefault: { $0.isEmpty }, write: { values, writer in
            writer.beginArray()
            for value in values {
                writer.element()
                value.write(to: &writer)
            }
            writer.endArray()
        })
    }

    public static func enumeration<E: NSEnum>(_ number: Int, _ name: String, _ path: WritableKeyPath<Root, E>) -> NSField {
        make(number, name, path, isDefault: { $0 == .unknown }, write: { $1.string($0.rawValue) })
    }

    public static func enumList<E: NSEnum>(_ number: Int, _ name: String, _ path: WritableKeyPath<Root, [E]>) -> NSField {
        make(number, name, path, isDefault: { $0.isEmpty }, write: { $1.stringArray($0.map(\.rawValue)) })
    }

    public static func stringList(_ number: Int, _ name: String, _ path: WritableKeyPath<Root, [String]>) -> NSField {
        make(number, name, path, isDefault: { $0.isEmpty }, write: { $1.stringArray($0) })
    }

    /// DeviceStatus `error`, a nested message with one string field.
    public static func deviceError(
        _ number: Int, _ name: String, _ path: WritableKeyPath<Root, DeviceStatusError?>
    ) -> NSField {
        make(number, name, path, isDefault: { $0 == nil }, write: { value, writer in
            writer.beginObject()
            if let message = value?.errorMessage, !message.isEmpty {
                writer.key("errorMessage")
                writer.string(message)
            }
            writer.endObject()
        })
    }
}

/// DeviceStatus `error`: `{"errorMessage": "..."}`.
public struct DeviceStatusError: Sendable, Equatable, Codable {
    public var errorMessage: String

    public init(errorMessage: String) {
        self.errorMessage = errorMessage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: NSJSONKey.self)
        errorMessage = try container.decodeIfPresent(String.self, forKey: NSJSONKey("errorMessage")) ?? ""
    }
}
