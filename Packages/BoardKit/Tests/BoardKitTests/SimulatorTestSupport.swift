import BoardProtocol
import Foundation
@testable import BoardKit

/// Drives a manual-time simulator and collects everything it emitted.
struct SimHarness {
    let transport: SimulatedBoardTransport
    let events: AsyncStream<BoardEvent>
    private var nextRequestID: UInt32 = 1

    init(boards: Int = 1, seed: UInt64 = 42) {
        transport = SimulatedBoardTransport(
            boardCount: boards, seed: seed, timeSource: .manual,
            startDate: Date(timeIntervalSince1970: 1_800_000_000)
        )
        events = transport.events()
    }

    var boardIDs: [BoardID] { transport.profiles.map(\.id) }

    @discardableResult
    mutating func send(_ command: NSBControlRequest.OneOf_Command, to id: BoardID) async throws -> NSBControlResponse {
        var request = NSBControlRequest()
        request.requestID = nextRequestID
        nextRequestID += 1
        request.command = command
        return try await transport.send(request, to: id)
    }

    mutating func hello(_ id: BoardID) async throws {
        var hello = NSBHello()
        hello.protocolMajor = 1
        try await send(.hello(hello), to: id)
        var time = NSBSetTime()
        time.unixTimeMs = 1_800_000_000_000
        try await send(.setTime(time), to: id)
    }

    /// Connects, says hello, configures and starts a board.
    @discardableResult
    mutating func startSurvey(_ id: BoardID, role: NSBRole = .auto, channels: [UInt32] = [], ble: Bool = true) async throws -> NSBControlResponse {
        try await transport.connect(id)
        try await hello(id)
        let response = try await send(.configure(.make(role: role, channels: channels, ble: ble)), to: id)
        try await send(.start(NSBStart()), to: id)
        return response
    }

    /// Ends the streams and returns every event emitted so far.
    func finish() async -> [BoardEvent] {
        await transport.shutdown()
        var all: [BoardEvent] = []
        for await event in events { all.append(event) }
        return all
    }
}

extension NSBConfigure {
    static func make(role: NSBRole, channels: [UInt32] = [], ble: Bool = true) -> NSBConfigure {
        var config = NSBConfigure()
        config.wifiAp = true
        config.wifiClient = true
        config.wifiProbes = true
        config.ble = ble
        config.role = role
        config.channels = channels
        return config
    }
}

extension [BoardEvent] {
    var batches: [ReceivedRecordBatch] {
        compactMap { if case .records(_, let batch) = $0 { batch } else { nil } }
    }

    var records: [NSBRecord] { batches.flatMap(\.batch.records) }

    var statuses: [NSBBoardStatus] {
        compactMap { if case .status(_, let status) = $0 { status } else { nil } }
    }

    var states: [BoardConnectionState] {
        compactMap { if case .connectionState(_, let state) = $0 { state } else { nil } }
    }

    func records(from board: BoardID) -> [NSBRecord] {
        compactMap { if case .records(board, let batch) = $0 { batch.batch.records } else { nil } }.flatMap { $0 }
    }
}

extension NSBRecord {
    /// Receive channel for Wi-Fi client and probe records, AP channel for APs.
    var wifiChannel: UInt32? {
        switch kind {
        case .ap(let ap): ap.channel
        case .client(let client): client.channel
        case .probe(let probe): probe.channel
        default: nil
        }
    }

    var band: NSBBand? {
        switch kind {
        case .ap(let ap): ap.band
        case .client(let client): client.band
        case .probe(let probe): probe.band
        default: nil
        }
    }

    var isBLE: Bool {
        if case .ble = kind { return true }
        return false
    }
}
