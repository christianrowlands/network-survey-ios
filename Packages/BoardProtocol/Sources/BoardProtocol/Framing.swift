import Foundation
import SwiftProtobuf

/// Framing used on every notify and indicate characteristic of a board.
///
/// A notification is a little-endian `UInt16` sequence number followed by one or
/// more protobuf messages, each prefixed with its length as a varint. A message
/// never spans notifications. The sequence number counts notifications per
/// characteristic and wraps from 65535 to 0.
public enum BoardFraming {
    public static let headerSize = 2

    /// The largest message that fits alone in a notification of `maxPayload` bytes.
    public static func maxMessageSize(maxPayload: Int) -> Int {
        var size = maxPayload - headerSize - 1
        while size > 0, headerSize + varintSize(size) + size > maxPayload {
            size -= 1
        }
        return max(size, 0)
    }

    public static func encode(sequence: UInt16, messages: [Data]) -> Data {
        var out = Data(capacity: headerSize + messages.reduce(0) { $0 + $1.count + 5 })
        out.append(UInt8(sequence & 0xFF))
        out.append(UInt8(sequence >> 8))
        for message in messages {
            appendVarint(UInt32(message.count), to: &out)
            out.append(message)
        }
        return out
    }

    public static func decode(_ notification: Data) throws(BoardFramingError) -> BoardFrame {
        let bytes = [UInt8](notification)
        guard bytes.count >= headerSize else { throw .missingHeader }
        let sequence = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        var messages: [Data] = []
        var offset = headerSize
        while offset < bytes.count {
            let start = offset
            var length: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard offset < bytes.count, shift < 35 else { throw .malformedLength(offset: start) }
                let byte = bytes[offset]
                offset += 1
                length |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { break }
                shift += 7
            }
            guard length <= UInt64(bytes.count - offset) else {
                throw .truncatedMessage(offset: start, length: Int(length))
            }
            messages.append(Data(bytes[offset..<offset + Int(length)]))
            offset += Int(length)
        }
        return BoardFrame(sequence: sequence, messages: messages)
    }

    /// Decodes a notification and parses every message in it as `M`.
    public static func decode<M: Message>(
        _ notification: Data, as type: M.Type
    ) throws -> (sequence: UInt16, messages: [M]) {
        let frame = try decode(notification)
        return (frame.sequence, try frame.messages.map { try M(serializedBytes: $0) })
    }

    /// Packs messages, in order, into as few notifications of at most `maxPayload`
    /// bytes as possible. Sequence numbers start at `firstSequence` and wrap.
    public static func pack(
        _ messages: [Data], maxPayload: Int, firstSequence: UInt16
    ) throws(BoardFramingError) -> [Data] {
        let limit = maxMessageSize(maxPayload: maxPayload)
        var frames: [Data] = []
        var pending: [Data] = []
        var used = headerSize
        var sequence = firstSequence
        for message in messages {
            guard message.count <= limit else {
                throw .messageTooLarge(size: message.count, limit: limit)
            }
            let size = varintSize(message.count) + message.count
            if used + size > maxPayload {
                frames.append(encode(sequence: sequence, messages: pending))
                sequence &+= 1
                pending = []
                used = headerSize
            }
            pending.append(message)
            used += size
        }
        if !pending.isEmpty {
            frames.append(encode(sequence: sequence, messages: pending))
        }
        return frames
    }

    static func varintSize(_ value: Int) -> Int {
        var size = 1
        var rest = value >> 7
        while rest > 0 {
            size += 1
            rest >>= 7
        }
        return size
    }

    private static func appendVarint(_ value: UInt32, to data: inout Data) {
        var rest = value
        while rest >= 0x80 {
            data.append(UInt8(rest & 0x7F) | 0x80)
            rest >>= 7
        }
        data.append(UInt8(rest))
    }
}

public struct BoardFrame: Equatable, Sendable {
    public var sequence: UInt16
    public var messages: [Data]

    public init(sequence: UInt16, messages: [Data]) {
        self.sequence = sequence
        self.messages = messages
    }
}

public enum BoardFramingError: Error, Equatable, Sendable {
    case missingHeader
    case malformedLength(offset: Int)
    case truncatedMessage(offset: Int, length: Int)
    case messageTooLarge(size: Int, limit: Int)
}

/// Tracks the sequence numbers of one characteristic and counts missed notifications.
///
/// Create a fresh detector (or call `reset()`) for each connection, since the board
/// restarts its counters when the phone subscribes.
public struct SequenceGapDetector: Equatable, Sendable {
    public private(set) var lastSequence: UInt16?
    public private(set) var missedTotal = 0

    public init() {}

    /// Records a received sequence number and returns how many notifications were
    /// missed just before it. A backward step or a jump of 32768 or more is treated
    /// as a restart, not as loss.
    @discardableResult
    public mutating func observe(_ sequence: UInt16) -> Int {
        defer { lastSequence = sequence }
        guard let last = lastSequence else { return 0 }
        let gap = sequence &- last &- 1
        guard gap < 0x8000 else { return 0 }
        missedTotal += Int(gap)
        return Int(gap)
    }

    public mutating func reset() {
        lastSequence = nil
        missedTotal = 0
    }
}
