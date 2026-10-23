import Foundation

/// Writes JSON the way the Network Survey Android app sends it: protobuf
/// `JsonFormat.printer().preservingProtoFieldNames().omittingInsignificantWhitespace()`.
/// That means fields in field-number order, no whitespace, Java number
/// formatting and Gson's HTML-safe string escaping.
public struct NSJSONWriter {
    public private(set) var output = ""
    private var needsComma = [false]

    public init() {
        output.reserveCapacity(512)
    }

    public mutating func beginObject() {
        output.append("{")
        needsComma.append(false)
    }

    public mutating func endObject() {
        output.append("}")
        needsComma.removeLast()
    }

    public mutating func key(_ name: String) {
        if needsComma[needsComma.count - 1] { output.append(",") }
        needsComma[needsComma.count - 1] = true
        output.append("\"")
        output.append(name)
        output.append("\":")
    }

    public mutating func string(_ value: String) {
        output.append("\"")
        Self.escape(value, into: &output)
        output.append("\"")
    }

    public mutating func float(_ value: Float) {
        // JsonFormat quotes the special values.
        if value.isFinite { output.append(JavaNumberFormat.string(value)) } else { string(JavaNumberFormat.string(value)) }
    }

    public mutating func double(_ value: Double) {
        if value.isFinite { output.append(JavaNumberFormat.string(value)) } else { string(JavaNumberFormat.string(value)) }
    }

    public mutating func integer<T: BinaryInteger>(_ value: T) {
        output.append(String(value))
    }

    public mutating func bool(_ value: Bool) {
        output.append(value ? "true" : "false")
    }

    public mutating func stringArray(_ values: [String]) {
        output.append("[")
        for (index, value) in values.enumerated() {
            if index > 0 { output.append(",") }
            string(value)
        }
        output.append("]")
    }

    /// Gson's default escaping: quotes, backslash, control characters, the
    /// HTML-sensitive characters `< > & = '` and U+2028/U+2029.
    static func escape(_ value: String, into output: inout String) {
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output.append("\\\"")
            case "\\": output.append("\\\\")
            case "\n": output.append("\\n")
            case "\r": output.append("\\r")
            case "\t": output.append("\\t")
            case "\u{08}": output.append("\\b")
            case "\u{0C}": output.append("\\f")
            case "<", ">", "&", "=", "'", "\u{2028}", "\u{2029}":
                output.append(unicodeEscape(scalar.value))
            default:
                if scalar.value < 0x20 {
                    output.append(unicodeEscape(scalar.value))
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
    }

    private static func unicodeEscape(_ value: UInt32) -> String {
        let hex = String(value, radix: 16)
        return "\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
    }
}
