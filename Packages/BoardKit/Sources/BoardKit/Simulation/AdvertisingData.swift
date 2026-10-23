import Foundation

/// Builds BLE advertising payloads (AD structures) for simulated devices.
enum AdvertisingData {
    static let maxLegacyLength = 31

    static func build(name: String, serviceUUIDs: [UInt16], txPower: Int8?, manufacturer: (UInt16, [UInt8])?) -> [UInt8] {
        var out: [UInt8] = [0x02, 0x01, 0x06]  // Flags: LE General Discoverable, BR/EDR not supported.
        if !serviceUUIDs.isEmpty {
            out.append(UInt8(1 + 2 * serviceUUIDs.count))
            out.append(0x03)  // Complete list of 16-bit service UUIDs.
            for uuid in serviceUUIDs {
                out.append(UInt8(uuid & 0xFF))
                out.append(UInt8(uuid >> 8))
            }
        }
        if let txPower {
            out += [0x02, 0x0A, UInt8(bitPattern: txPower)]
        }
        if let (company, payload) = manufacturer {
            out.append(UInt8(3 + payload.count))
            out.append(0xFF)
            out += [UInt8(company & 0xFF), UInt8(company >> 8)]
            out += payload
        }
        let nameBytes = Array(name.utf8)
        let room = maxLegacyLength - out.count - 2
        if !nameBytes.isEmpty, room > 0 {
            let complete = nameBytes.count <= room
            let part = nameBytes.prefix(room)
            out.append(UInt8(1 + part.count))
            out.append(complete ? 0x09 : 0x08)  // Complete or shortened local name.
            out += part
        }
        return out
    }
}

extension AdvertisingData {
    /// The complete or shortened local name in an advertising payload.
    static func localName(in data: [UInt8]) -> String? {
        var offset = 0
        while offset < data.count {
            let length = Int(data[offset])
            guard length > 0, offset + length < data.count else { return nil }
            let type = data[offset + 1]
            if type == 0x08 || type == 0x09, length >= 2 {
                return String(decoding: data[(offset + 2)...(offset + length)], as: UTF8.self)
            }
            offset += length + 1
        }
        return nil
    }
}
