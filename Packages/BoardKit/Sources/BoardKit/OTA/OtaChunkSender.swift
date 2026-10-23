import BoardProtocol
import Foundation

/// Sends a firmware image to a board after a successful `OtaBegin`
/// (protocol.md section 10): chunks of `offset + bytes` written without
/// response, at most `window_bytes` unacknowledged, resending from the last
/// acknowledged offset on `OUT_OF_ORDER` or after `ackTimeout` of silence.
///
/// Chunk boundaries never move: every chunk starts at `start_offset` plus a
/// whole number of chunks, and the window is rounded down to whole chunks. So a
/// resend repeats the same chunks, and the board can answer the duplicate that
/// ends at its `next_offset` with an ack when the phone lost the last one.
///
/// Cancelling the calling task stops the transfer promptly with
/// `.transport(.cancelled)`; send `OtaAbort` afterwards if the image should go.
///
/// This is the transfer primitive only. OtaBegin/OtaEnd, signature checks and
/// the user-facing flow belong to the firmware update feature.
public struct OtaChunkSender: Sendable {
    public let transport: any BoardTransport
    public let board: BoardID
    public let image: Data
    public let parameters: NSBOtaBeginResult
    public var ackTimeout: Duration = .seconds(5)
    /// Resends in a row without progress (after silence or OUT_OF_ORDER) before giving up.
    public var maxSilentResends = 4

    public init(transport: any BoardTransport, board: BoardID, image: Data, parameters: NSBOtaBeginResult) {
        self.transport = transport
        self.board = board
        self.image = image
        self.parameters = parameters
    }

    /// Chunk size and window for a write limit: the chunk never exceeds the
    /// board's window, and the window is a whole number of chunks.
    static func layout(maxChunkSize: Int, windowBytes: Int, writeLimit: Int) -> (chunk: Int, window: Int) {
        var chunk = min(maxChunkSize, writeLimit - 4)
        if windowBytes > 0 { chunk = min(chunk, windowBytes) }
        guard chunk > 0 else { return (0, 0) }
        return (chunk, max(windowBytes / chunk, 1) * chunk)
    }

    /// Runs the transfer and returns when the board has acknowledged every byte.
    /// `progress` gets the acknowledged byte count.
    public func run(progress: @Sendable (Int) -> Void = { _ in }) async throws(OtaTransferError) {
        let total = image.count
        let first = Int(parameters.startOffset)
        guard first <= total else { throw .badParameters("start offset past the image end") }
        guard let writeLimit = await transport.maximumOTAWriteLength(for: board) else { throw .transport(.notConnected) }
        let (chunkSize, window) = Self.layout(
            maxChunkSize: Int(parameters.maxChunkSize), windowBytes: Int(parameters.windowBytes), writeLimit: writeLimit
        )
        guard chunkSize > 0 else { throw .badParameters("no room for image bytes in a write") }

        // Events use the board's stable ID once Info is known; `board` may be provisional.
        let stable = (try? await transport.readInfo(board)).flatMap(BoardID.init(info:)) ?? board
        let mailbox = AsyncMailbox<NSBOtaAck>()
        let events = transport.events()  // Subscribed now, before the first chunk.
        let listener = Task { [board] in
            for await event in events {
                if case .otaAck(let id, let ack) = event, id == board || id == stable { await mailbox.put(ack) }
            }
        }
        defer { listener.cancel() }

        var acked = first
        var sent = first
        var stalls = 0
        progress(acked)
        while acked < total {
            while sent < total {
                let end = min(sent + chunkSize, total)
                guard end - acked <= window else { break }
                guard !Task.isCancelled else { throw .transport(.cancelled) }
                do {
                    try await transport.writeOTAChunk(Self.chunk(image, from: sent, to: end), to: board)
                } catch {
                    throw .transport(error)
                }
                sent = end
            }
            let ack = await mailbox.take(timeout: ackTimeout)
            guard !Task.isCancelled else { throw .transport(.cancelled) }
            guard let ack else {
                stalls += 1
                guard stalls <= maxSilentResends else { throw .stalled(acknowledged: acked) }
                sent = acked
                continue
            }
            // The board only accepts whole chunks, so next_offset is on the chunk grid.
            let next = min(Int(ack.nextOffset), total)
            switch ack.status {
            case .ok, .outOfOrder:
                if next > acked {
                    acked = next
                    stalls = 0
                    progress(acked)
                } else if ack.status == .outOfOrder {
                    stalls += 1
                    guard stalls <= maxSilentResends else { throw .stalled(acknowledged: acked) }
                }
                sent = ack.status == .outOfOrder ? acked : max(sent, acked)
            default:
                throw .boardAborted(ack.status)
            }
        }
    }

    static func chunk(_ image: Data, from start: Int, to end: Int) -> Data {
        var out = Data(capacity: 4 + end - start)
        let offset = UInt32(start)
        out.append(contentsOf: [UInt8(offset & 0xFF), UInt8(offset >> 8 & 0xFF), UInt8(offset >> 16 & 0xFF), UInt8(offset >> 24)])
        out.append(image[image.startIndex + start ..< image.startIndex + end])
        return out
    }
}

public enum OtaTransferError: Error, Equatable, Sendable {
    case transport(BoardTransportError)
    case badParameters(String)
    /// The board stopped acknowledging.
    case stalled(acknowledged: Int)
    /// WRITE_FAILED, OVERFLOW or NOT_ACTIVE: start again with OtaBegin.
    case boardAborted(NSBOtaAckStatus)
}

/// A one-consumer queue with a timed take.
actor AsyncMailbox<Element: Sendable> {
    private var items: [Element] = []
    private var waiter: (id: UInt64, continuation: CheckedContinuation<Element?, Never>)?
    private var nextID: UInt64 = 0

    func put(_ item: Element) {
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: item)
        } else {
            items.append(item)
        }
    }

    /// The next element, or nil after `timeout` or when the calling task is cancelled.
    func take(timeout: Duration) async -> Element? {
        if !items.isEmpty { return items.removeFirst() }
        nextID &+= 1
        let id = nextID
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { self.expire(id) }
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                waiter = (id, continuation)
            }
        } onCancel: {
            Task { await self.expire(id) }
        }
    }

    private func expire(_ id: UInt64) {
        guard let waiter, waiter.id == id else { return }
        self.waiter = nil
        waiter.continuation.resume(returning: nil)
    }
}
