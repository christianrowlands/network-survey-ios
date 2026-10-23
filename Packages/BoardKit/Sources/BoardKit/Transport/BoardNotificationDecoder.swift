import BoardProtocol
import Foundation

/// Turns framed notifications from the board's notify and indicate
/// characteristics into messages, tracking sequence gaps. Used by every
/// transport, so the simulator exercises the same path as real hardware.
///
/// Call `reset()` whenever the phone (re)subscribes, since the board restarts
/// its sequence numbers then.
public struct BoardNotificationDecoder: Sendable {
    public private(set) var records = SequenceGapDetector()
    public private(set) var status = SequenceGapDetector()
    public private(set) var raw = SequenceGapDetector()
    public private(set) var control = SequenceGapDetector()
    public private(set) var ota = SequenceGapDetector()

    public init() {}

    public mutating func reset() {
        self = BoardNotificationDecoder()
    }

    /// Decodes one Records notification. A notification may carry several batches;
    /// the gap count is reported on the first.
    public mutating func decodeRecords(_ notification: Data, receivedAt: Date) throws -> [ReceivedRecordBatch] {
        let frame = try BoardFraming.decode(notification)
        let missed = records.observe(frame.sequence)
        return try frame.messages.enumerated().map { index, bytes in
            ReceivedRecordBatch(
                sequence: frame.sequence,
                missedNotifications: index == 0 ? missed : 0,
                batch: try NSBRecordBatch(serializedBytes: bytes),
                receivedAt: receivedAt
            )
        }
    }

    public mutating func decodeStatus(_ notification: Data) throws -> [NSBBoardStatus] {
        let frame = try BoardFraming.decode(notification)
        status.observe(frame.sequence)
        return try frame.messages.map { try NSBBoardStatus(serializedBytes: $0) }
    }

    public mutating func decodeRaw(_ notification: Data, receivedAt: Date) throws -> ReceivedRawFrames {
        let frame = try BoardFraming.decode(notification)
        let missed = raw.observe(frame.sequence)
        return ReceivedRawFrames(
            sequence: frame.sequence, missedNotifications: missed,
            frames: try frame.messages.map { try NSBRawFrame(serializedBytes: $0) }, receivedAt: receivedAt
        )
    }

    /// Control indications: the raw `ControlResponse` messages, so the caller can
    /// match request IDs and decode them where needed.
    public mutating func decodeControl(_ indication: Data) throws -> [NSBControlResponse] {
        let frame = try BoardFraming.decode(indication)
        control.observe(frame.sequence)
        return try frame.messages.map { try NSBControlResponse(serializedBytes: $0) }
    }

    public mutating func decodeOtaAcks(_ notification: Data) throws -> [NSBOtaAck] {
        let frame = try BoardFraming.decode(notification)
        ota.observe(frame.sequence)
        return try frame.messages.map { try NSBOtaAck(serializedBytes: $0) }
    }
}
