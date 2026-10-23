import Foundation
import Testing
@testable import BoardProtocol

private func message(_ size: Int, fill: UInt8 = 0x5A) -> Data {
    Data(repeating: fill, count: size)
}

@Suite struct FramingTests {
    @Test func encodeLayout() {
        let frame = BoardFraming.encode(sequence: 0x0102, messages: [Data([0xAA]), Data()])
        #expect(frame == Data([0x02, 0x01, 0x01, 0xAA, 0x00]))
    }

    @Test func decodeRoundTrip() throws {
        let messages = [message(1), message(127), message(128), message(300)]
        let frame = BoardFraming.encode(sequence: 65535, messages: messages)
        let decoded = try BoardFraming.decode(frame)
        #expect(decoded == BoardFrame(sequence: 65535, messages: messages))
    }

    @Test func decodeSlicedData() throws {
        // Data slices have a non-zero start index.
        let padded = Data([0xFF, 0xFF]) + BoardFraming.encode(sequence: 9, messages: [message(3)])
        let decoded = try BoardFraming.decode(padded.dropFirst(2))
        #expect(decoded.sequence == 9)
        #expect(decoded.messages == [message(3)])
    }

    @Test func headerOnlyIsEmpty() throws {
        #expect(try BoardFraming.decode(Data([0x05, 0x00])).messages.isEmpty)
    }

    @Test func decodeErrors() {
        #expect(throws: BoardFramingError.missingHeader) { try BoardFraming.decode(Data([0x01])) }
        #expect(throws: BoardFramingError.truncatedMessage(offset: 2, length: 4)) {
            try BoardFraming.decode(Data([0x00, 0x00, 0x04, 0x01, 0x02]))
        }
        #expect(throws: BoardFramingError.malformedLength(offset: 2)) {
            try BoardFraming.decode(Data([0x00, 0x00, 0x80]))
        }
        #expect(throws: BoardFramingError.malformedLength(offset: 2)) {
            try BoardFraming.decode(Data([0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]))
        }
    }

    @Test(arguments: [3, 20, 129, 130, 131, 182, 244, 512])
    func maxMessageSizeFillsPayload(maxPayload: Int) throws {
        let size = BoardFraming.maxMessageSize(maxPayload: maxPayload)
        let frames = try BoardFraming.pack([message(size)], maxPayload: maxPayload, firstSequence: 0)
        #expect(frames.count == 1)
        #expect(frames[0].count <= maxPayload)
        // One more byte must not fit alone.
        #expect(BoardFraming.varintSize(size + 1) + size + 1 + BoardFraming.headerSize > maxPayload)
    }

    @Test func packExactFitAndOneOver() throws {
        // 244-byte payload: header 2, so two messages of 120 bytes (1 + 120 each) fill it exactly.
        let exact = try BoardFraming.pack([message(120), message(120)], maxPayload: 244, firstSequence: 7)
        #expect(exact.count == 1)
        #expect(exact[0].count == 244)

        let over = try BoardFraming.pack([message(120), message(121)], maxPayload: 244, firstSequence: 7)
        #expect(over.count == 2)
        #expect(try BoardFraming.decode(over[0]) == BoardFrame(sequence: 7, messages: [message(120)]))
        #expect(try BoardFraming.decode(over[1]) == BoardFrame(sequence: 8, messages: [message(121)]))
    }

    @Test func packSplitsAndJoinsInOrder() throws {
        let messages = (0..<50).map { message(10 + $0 * 3, fill: UInt8($0)) }
        for maxPayload in [185, 244, 512] {
            let frames = try BoardFraming.pack(messages, maxPayload: maxPayload, firstSequence: 65534)
            #expect(frames.allSatisfy { $0.count <= maxPayload })
            var joined: [Data] = []
            var detector = SequenceGapDetector()
            for frame in frames {
                let decoded = try BoardFraming.decode(frame)
                #expect(detector.observe(decoded.sequence) == 0)
                joined += decoded.messages
            }
            #expect(joined == messages)
            #expect(try BoardFraming.decode(frames[0]).sequence == 65534)
            #expect(try BoardFraming.decode(frames[2]).sequence == 0)
        }
    }

    @Test func packRejectsOversizedMessage() {
        let limit = BoardFraming.maxMessageSize(maxPayload: 244)
        #expect(limit == 240)
        #expect(throws: BoardFramingError.messageTooLarge(size: 241, limit: 240)) {
            try BoardFraming.pack([message(241)], maxPayload: 244, firstSequence: 0)
        }
    }

    @Test func decodeTypedMessages() throws {
        let acks = [NSBOtaAck.with { $0.nextOffset = 512; $0.status = .ok },
                    NSBOtaAck.with { $0.nextOffset = 1024; $0.status = .ok }]
        let frame = BoardFraming.encode(sequence: 3, messages: try acks.map { try $0.serializedData() })
        let decoded = try BoardFraming.decode(frame, as: NSBOtaAck.self)
        #expect(decoded.sequence == 3)
        #expect(decoded.messages == acks)
    }
}

@Suite struct SequenceGapDetectorTests {
    @Test func firstSequenceIsNeverAGap() {
        var detector = SequenceGapDetector()
        #expect(detector.observe(1234) == 0)
        #expect(detector.lastSequence == 1234)
    }

    @Test func consecutiveAcrossWrap() {
        var detector = SequenceGapDetector()
        for sequence: UInt16 in [65533, 65534, 65535, 0, 1, 2] {
            #expect(detector.observe(sequence) == 0)
        }
        #expect(detector.missedTotal == 0)
    }

    @Test func gapAcrossWrap() {
        var detector = SequenceGapDetector()
        detector.observe(65534)
        #expect(detector.observe(2) == 3)  // 65535, 0, 1 missing
        #expect(detector.observe(3) == 0)
        #expect(detector.observe(10) == 6)
        #expect(detector.missedTotal == 9)
    }

    @Test func largestCountedGap() {
        var detector = SequenceGapDetector()
        detector.observe(100)
        #expect(detector.observe(100 &+ 0x8000) == 0x7FFF)
    }

    @Test func backwardStepIsARestart() {
        var detector = SequenceGapDetector()
        detector.observe(500)
        #expect(detector.observe(0) == 0)  // board restarted its counter
        #expect(detector.observe(1) == 0)
        #expect(detector.observe(1) == 0)  // duplicate
        #expect(detector.observe(3) == 1)
        #expect(detector.missedTotal == 1)
    }

    @Test func resetForgetsHistory() {
        var detector = SequenceGapDetector()
        detector.observe(10)
        detector.observe(20)
        detector.reset()
        #expect(detector.lastSequence == nil && detector.missedTotal == 0)
        #expect(detector.observe(40) == 0)
    }
}

/// The hex examples in docs/protocol.md section 14, so the doc cannot drift.
@Suite struct ProtocolDocExampleTests {
    @Test func pingRequest() throws {
        let request = NSBControlRequest.with { $0.requestID = 5; $0.ping = .with { $0.nonce = 1 } }
        #expect(try request.serializedData() == Data([0x08, 0x05, 0x62, 0x02, 0x08, 0x01]))
    }

    @Test func pingResponseFrame() throws {
        let response = NSBControlResponse.with {
            $0.requestID = 5
            $0.result = .ok
            $0.ping = .with { $0.nonce = 1; $0.boardTimeMs = 1_767_225_600_123; $0.timeSynced = true }
        }
        let frame = BoardFraming.encode(sequence: 0, messages: [try response.serializedData()])
        #expect(frame == Data([0x00, 0x00, 0x11, 0x08, 0x05, 0x10, 0x01, 0x3A, 0x0B, 0x08, 0x01,
                               0x10, 0xFB, 0xD0, 0xEA, 0xB6, 0xB7, 0x33, 0x18, 0x01]))
    }

    @Test func otaAckFrame() throws {
        let ack = NSBOtaAck.with { $0.nextOffset = 4096; $0.status = .ok }
        let frame = BoardFraming.encode(sequence: 258, messages: [try ack.serializedData()])
        #expect(frame == Data([0x02, 0x01, 0x05, 0x08, 0x80, 0x20, 0x10, 0x01]))
    }
}
