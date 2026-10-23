import Foundation

/// Bluetooth company identifiers from the bundled Bluetooth SIG
/// `company_identifiers.yaml` (the list the Network Survey Android app ships,
/// refreshed by scripts/update-bluetooth-numbers.sh).
nonisolated enum BLECompanies {
    static func name(for id: Int) -> String? {
        names[id]
    }

    /// "0x004C".
    static func hexID(_ id: Int) -> String {
        "0x" + String(format: "%04X", id)
    }

    /// Loaded on first use; about 4,000 entries.
    static let names = AssignedNumbers.load("company_identifiers", idKey: "value")
}

/// Names for 16-bit service UUIDs: GATT services from `service_uuids.yaml`
/// ("Human Interface Device") and UUIDs assigned to members from
/// `member_uuids.yaml` ("Google LLC").
nonisolated enum BLEServiceUUIDs {
    static let services = AssignedNumbers.load("service_uuids", idKey: "uuid")
    static let members = AssignedNumbers.load("member_uuids", idKey: "uuid")

    /// The service or member name for a full UUID on the Bluetooth base
    /// ("0000FE9F-0000-1000-8000-00805F9B34FB") or a short one ("FE9F").
    static func name(forUUID uuid: String) -> String? {
        shortID(uuid).flatMap { services[$0] ?? members[$0] }
    }

    /// "0x1812" for UUIDs on the Bluetooth base, else the full UUID in upper case.
    static func display(_ uuid: String) -> String {
        shortID(uuid).map { String(format: "0x%04X", $0) } ?? uuid.uppercased()
    }

    static func shortID(_ uuid: String) -> Int? {
        let upper = uuid.uppercased()
        if upper.count == 4 { return Int(upper, radix: 16) }
        guard upper.count == 36, upper.hasPrefix("0000"), upper.hasSuffix("-0000-1000-8000-00805F9B34FB") else { return nil }
        return Int(upper.dropFirst(4).prefix(4), radix: 16)
    }
}

/// Reads the Bluetooth SIG assigned numbers YAML lists: entries of
/// `- <idKey>: 0xXXXX` followed by `name: ...` (plain, 'single' or "double" quoted).
nonisolated enum AssignedNumbers {
    static func load(_ resource: String, idKey: String) -> [Int: String] {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "yaml"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return parse(text, idKey: idKey)
    }

    static func parse(_ text: String, idKey: String) -> [Int: String] {
        var result: [Int: String] = [:]
        var current: Int?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("- \(idKey):") {
                let value = line.dropFirst(idKey.count + 3).trimmingCharacters(in: .whitespaces)
                current = value.lowercased().hasPrefix("0x") ? Int(value.dropFirst(2), radix: 16) : Int(value)
            } else if line.hasPrefix("name:"), let id = current {
                let name = unquote(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
                if !name.isEmpty { result[id] = name }
                current = nil
            }
        }
        return result
    }

    private static func unquote(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        }
        return value
    }
}
