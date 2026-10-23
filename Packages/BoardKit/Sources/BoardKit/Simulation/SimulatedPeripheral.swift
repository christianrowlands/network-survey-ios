import BoardProtocol
import CryptoKit
import Foundation
import SwiftProtobuf

/// One simulated board as a GATT peripheral: bonding and link encryption, the
/// framed characteristics, the control channel and an OTA receiver, on top of
/// `SimulatedBoardEngine`. Methods return the central events they cause.
struct SimulatedPeripheral {
    static let ringCapacity = 4000
    static let writeCredits = 4
    static let otaWindowBytes: UInt32 = 4096

    let id: UUID
    var engine: SimulatedBoardEngine

    var inRange = true
    var connected = false
    var connecting = false
    var encrypted = false
    /// Both sides hold the bond.
    var phoneBonded = false
    /// The phone kept keys the board deleted (ForgetBonds or a button wipe).
    var staleBondOnPhone = false
    /// iOS reports some stale bonds as an encryption timeout (CBError 15) instead of CBError 14.
    var staleBondTimesOut = false
    var userAcceptsPairing = true
    var subscribed: Set<BoardCharacteristic> = []
    var sequences: [BoardCharacteristic: UInt16] = [:]
    var ring: [NSBRecordBatch] = []
    var ringRecords = 0

    // Fault injection.
    var connectFailures = 0
    var notificationsToLose = 0
    var controlResponsesToDrop = 0
    var otaChunksToDrop: Set<Int> = []
    var controlWritesToCorrupt = 0
    var otaAckOffsetsToDrop: Set<UInt32> = []
    var maxOTABytesAheadOfAck = 0

    // Control timing and accounting.
    var controlLatencyMs: UInt64 = 0
    var pendingControl: [(dueMs: UInt64, response: NSBControlResponse)] = []
    var outstandingControl = 0
    var maxOutstandingControl = 0

    // Write without response flow control and OTA.
    var credits = writeCredits
    var ota: SimulatedOtaReceiver?
    var otaChunkCount = 0
    var installedImage: Data?

    init(id: UUID, engine: SimulatedBoardEngine, pairedWithPhone: Bool) {
        self.id = id
        self.engine = engine
        phoneBonded = pairedWithPhone
        self.engine.bondCount = pairedWithPhone ? 1 : 0
    }

    var profile: SimulatedBoardProfile { engine.profile }
    var pairable: Bool { engine.bondCount == 0 || engine.pairingMode }
    var advertising: Bool { inRange && (!connected || engine.pairingMode) }

    var advertisement: BLEAdvertisementData {
        let manufacturer = BoardAdvertisement(
            protocolMajor: UInt8(truncatingIfNeeded: profile.protocolMajor), pairable: pairable,
            hasBond: engine.bondCount > 0, hasGPS: false, supports5GHz: profile.bands.contains(.ghz5), model: profile.model
        )
        return BLEAdvertisementData(
            localName: profile.name, serviceUUIDs: [BoardGATT.serviceUUID], manufacturerData: manufacturer.encoded,
            isConnectable: true
        )
    }

    mutating func dropLink() {
        connected = false
        encrypted = false
        subscribed = []
        pendingControl = []
        outstandingControl = 0
        engine.linkDropped()
    }

    /// The board's rule for encrypted characteristics, plus what iOS does.
    mutating func authorize() -> BLEError? {
        if encrypted { return nil }
        if staleBondOnPhone { return staleBondTimesOut ? .encryptionTimedOut : .peerRemovedPairing }
        if phoneBonded {
            encrypted = true
            return nil
        }
        guard pairable, userAcceptsPairing else { return .insufficientAuthentication }
        // Just Works pairing: one bond, which replaces any other.
        phoneBonded = true
        encrypted = true
        engine.bondCount = 1
        engine.pairingMode = false
        return nil
    }

    mutating func subscribe(_ characteristic: BoardCharacteristic, enabled: Bool) -> [BLECentralEvent] {
        if characteristic.isEncrypted, let error = authorize() {
            return [.notifyStateChanged(id, characteristic, enabled: false, error)]
        }
        guard enabled else {
            subscribed.remove(characteristic)
            return [.notifyStateChanged(id, characteristic, enabled: false, nil)]
        }
        subscribed.insert(characteristic)
        sequences[characteristic] = 0
        var events: [BLECentralEvent] = [.notifyStateChanged(id, characteristic, enabled: true, nil)]
        if characteristic == .records {
            let buffered = ring
            ring = []
            ringRecords = 0
            engine.ringFillPercent = 0
            events += buffered.compactMap { notify(.records, [Self.encode($0)]) }
        }
        return events
    }

    // MARK: - Control

    /// Returns the events of a control write, and whether the board then drops the link.
    mutating func writeControl(_ data: Data, nowMs: UInt64) -> (events: [BLECentralEvent], disconnect: Bool) {
        if let error = authorize() { return ([.wroteValue(id, .control, error)], false) }
        var events: [BLECentralEvent] = [.wroteValue(id, .control, nil)]
        outstandingControl += 1
        maxOutstandingControl = max(maxOutstandingControl, outstandingControl)
        let response: NSBControlResponse
        var disconnect = false
        if controlWritesToCorrupt > 0 {
            controlWritesToCorrupt -= 1
            response = .with {
                $0.requestID = 0
                $0.result = .invalidArgument
                $0.message = "could not decode request"
            }
        } else if let request = try? NSBControlRequest(serializedBytes: data) {
            response = handle(request)
            if case .forgetBonds? = request.command {
                // The board wipes its bonds and drops us; the phone keeps its half.
                phoneBonded = false
                staleBondOnPhone = true
                disconnect = true
            }
        } else {
            response = .with {
                $0.requestID = 0
                $0.result = .invalidArgument
                $0.message = "could not decode request"
            }
        }
        if controlResponsesToDrop > 0 {
            controlResponsesToDrop -= 1
            outstandingControl -= 1
        } else if controlLatencyMs > 0, !disconnect {
            pendingControl.append((nowMs + controlLatencyMs, response))
        } else {
            events += indicate(response)
        }
        return (events, disconnect)
    }

    private mutating func indicate(_ response: NSBControlResponse) -> [BLECentralEvent] {
        outstandingControl = max(outstandingControl - 1, 0)
        return notify(.control, [Self.encode(response)]).map { [$0] } ?? []
    }

    private mutating func handle(_ request: NSBControlRequest) -> NSBControlResponse {
        var response = NSBControlResponse()
        response.requestID = request.requestID
        response.result = .ok
        switch request.command {
        case .otaBegin(let begin):
            guard begin.imageSize > 0, begin.sha256.count == 32 else {
                response.result = .invalidArgument
                return response
            }
            let resume = ota.map { $0.size == Int(begin.imageSize) && $0.sha256 == begin.sha256 } ?? false
            if !resume {
                ota = SimulatedOtaReceiver(size: Int(begin.imageSize), sha256: begin.sha256, window: Int(Self.otaWindowBytes))
            }
            response.payload = .otaBegin(.with {
                $0.maxChunkSize = profile.mtu - 3 - 4
                $0.windowBytes = Self.otaWindowBytes
                $0.startOffset = UInt32(ota?.image.count ?? 0)
            })
        case .otaEnd:
            guard let receiver = ota, receiver.image.count == receiver.size else {
                response.result = .invalidState
                return response
            }
            ota = nil
            if Data(SHA256.hash(data: receiver.image)) == receiver.sha256 {
                installedImage = receiver.image
            } else {
                response.result = .otaVerifyFailed
            }
        case .otaAbort:
            ota = nil
        default:
            response = engine.handle(request)
        }
        return response
    }

    // MARK: - OTA

    mutating func writeOTA(_ chunk: Data) -> [BLECentralEvent] {
        guard encrypted else { return [] }
        credits = max(credits - 1, 0)
        otaChunkCount += 1
        if let receiver = ota, chunk.count > 4 {
            let offset = chunk.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            maxOTABytesAheadOfAck = max(maxOTABytesAheadOfAck, offset + chunk.count - 4 - receiver.lastAcked)
        }
        if otaChunksToDrop.contains(otaChunkCount) { return [] }
        guard var receiver = ota else {
            return notify(.ota, [Self.encode(NSBOtaAck.with { $0.status = .notActive })]).map { [$0] } ?? []
        }
        let acks = receiver.receive(chunk)
        ota = acks.contains { $0.status == .overflow } ? nil : receiver
        return acks.compactMap { ack in
            otaAckOffsetsToDrop.remove(ack.nextOffset) != nil ? nil : notify(.ota, [Self.encode(ack)])
        }
    }

    // MARK: - Time

    mutating func advance(byMs ms: UInt64, nowMs: UInt64) -> [BLECentralEvent] {
        var events: [BLECentralEvent] = []
        while let next = pendingControl.first, next.dueMs <= nowMs {
            pendingControl.removeFirst()
            events += indicate(next.response)
        }
        for output in engine.advance(byMs: ms) {
            switch output {
            case .status(let status):
                if let event = notify(.status, [Self.encode(status)]) { events.append(event) }
            case .records(let batch):
                if connected, subscribed.contains(.records) {
                    if let event = notify(.records, [Self.encode(batch)]) { events.append(event) }
                } else {
                    buffer(batch)
                }
            case .rawFrames(let frames):
                // Raw frames are not buffered while disconnected, as on the board.
                events += frames.compactMap { notify(.raw, [Self.encode($0)]) }
            }
        }
        return events
    }

    private mutating func buffer(_ batch: NSBRecordBatch) {
        if ringRecords + batch.records.count > Self.ringCapacity {
            engine.droppedRecords &+= UInt32(batch.records.count)
        } else {
            ring.append(batch)
            ringRecords += batch.records.count
        }
        engine.ringFillPercent = UInt32(ringRecords * 100 / Self.ringCapacity)
    }

    /// Frames messages for a characteristic. Every attempt uses a sequence
    /// number, so an injected loss shows up as a gap.
    private mutating func notify(_ characteristic: BoardCharacteristic, _ messages: [Data]) -> BLECentralEvent? {
        guard connected, encrypted, subscribed.contains(characteristic) else { return nil }
        let sequence = sequences[characteristic, default: 0]
        sequences[characteristic] = sequence &+ 1
        if characteristic == .records, notificationsToLose > 0 {
            notificationsToLose -= 1
            return nil
        }
        return .valueUpdated(id, characteristic, BoardFraming.encode(sequence: sequence, messages: messages), nil)
    }

    static func encode(_ message: some SwiftProtobuf.Message) -> Data {
        (try? message.serializedData()) ?? Data()
    }
}

/// The board side of an OTA transfer (protocol.md section 10).
struct SimulatedOtaReceiver {
    let size: Int
    let sha256: Data
    let window: Int
    var image = Data()
    var lastAcked = 0
    var outOfOrderSent = false

    mutating func receive(_ chunk: Data) -> [NSBOtaAck] {
        let bytes = [UInt8](chunk)
        guard bytes.count > 4 else { return [] }
        let offset = Int(UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)
        let payload = bytes[4...]
        if offset < image.count {
            // A duplicate after a resend: only the one ending at next_offset is
            // answered, so a phone that lost the last ack learns where we are.
            return offset + payload.count == image.count ? [ack(.ok)] : []
        }
        if offset > image.count {
            guard !outOfOrderSent else { return [] }
            outOfOrderSent = true
            return [ack(.outOfOrder)]
        }
        guard offset + payload.count <= size else { return [ack(.overflow)] }
        image.append(contentsOf: payload)
        outOfOrderSent = false
        guard image.count - lastAcked >= window / 2 || image.count == size else { return [] }
        lastAcked = image.count
        return [ack(.ok)]
    }

    private func ack(_ status: NSBOtaAckStatus) -> NSBOtaAck {
        .with {
            $0.nextOffset = UInt32(image.count)
            $0.status = status
        }
    }
}
