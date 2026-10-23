import BoardProtocol
import Foundation
import SwiftProtobuf

/// The firmware of one simulated board: control commands, the channel plan for
/// its role, per-dwell record generation and 1 Hz status. Time only moves when
/// `advance(byMs:)` is called, so a run is fully determined by the seed and the
/// sequence of calls.
struct SimulatedBoardEngine: Sendable {
    enum Output: Sendable, Equatable {
        case records(NSBRecordBatch)
        case status(NSBBoardStatus)
        /// Raw 802.11 frames for the Raw characteristic (only with Configure.raw_frames).
        case rawFrames([NSBRawFrame])
    }

    static let defaultDwell24Ms: UInt32 = 200
    static let defaultDwell5Ms: UInt32 = 120
    /// BLE scan window of a BLE sniffer, and the interleave period of an AUTO
    /// board (20 ms of every 100 ms scanning, reported once per period).
    static let sniffWindowMs: UInt64 = 250
    static let interleavePeriodMs: UInt64 = 1000
    static let interleaveDutyCycle = 0.2
    /// RecordBatch.records max_count in ns_board.options.
    static let maxRecordsPerBatch = 12

    let profile: SimulatedBoardProfile
    let world: SimulatedWorld
    var rng: SeededGenerator

    private(set) var uptimeMs: UInt64 = 0
    private var epochOffsetMs: UInt64?
    private(set) var helloCompleted = false
    private(set) var running = false
    private(set) var configuration: NSBConfigure
    private(set) var channels: [UInt32]
    var pairingMode = false
    var bondCount: UInt32 = 1

    private var channelIndex = 0
    private(set) var currentChannel: UInt32 = 0
    private var dwellEndMs: UInt64 = 0
    private var nextBLEWindowMs: UInt64 = 0
    private var nextStatusMs: UInt64 = 1000
    private var recordsThisSecond: UInt32 = 0
    private var framesThisSecond: UInt32 = 0
    /// Raw frames sent this second, against Configure.raw_max_frames_per_sec.
    var rawFramesThisSecond: UInt32 = 0

    /// Set by the transport, which owns the ring buffer.
    var droppedRecords: UInt32 = 0
    var ringFillPercent: UInt32 = 0

    init(profile: SimulatedBoardProfile, world: SimulatedWorld, seed: UInt64) {
        self.profile = profile
        self.world = world
        rng = SeededGenerator(seed: seed).derived(UInt64(profile.shortID, radix: 16) ?? 0)
        var config = NSBConfigure()
        config.wifiAp = true
        config.wifiClient = true
        config.wifiProbes = true
        config.ble = true
        config.role = .auto
        configuration = config
        channels = profile.supportedChannels
    }

    var timeSynced: Bool { epochOffsetMs != nil }

    /// Board time in the protocol's time base: epoch ms once synced, else uptime.
    func boardTime(atUptime ms: UInt64) -> UInt64 {
        ms + (epochOffsetMs ?? 0)
    }

    // MARK: - Control

    mutating func handle(_ request: NSBControlRequest) -> NSBControlResponse {
        var response = NSBControlResponse()
        response.requestID = request.requestID
        response.result = .ok
        switch request.command {
        case .hello(let hello):
            var result = NSBHelloResult()
            result.protocolMajor = profile.protocolMajor
            result.protocolMinor = UInt32(NSBProtocolVersion.minor.rawValue)
            result.compatible = hello.protocolMajor == result.protocolMajor
            result.firmwareVersion = profile.firmwareVersion
            helloCompleted = result.compatible
            response.result = result.compatible ? .ok : .incompatible
            response.payload = .hello(result)
        case .ping(let ping):
            var result = NSBPingResult()
            result.nonce = ping.nonce
            result.boardTimeMs = boardTime(atUptime: uptimeMs)
            result.timeSynced = timeSynced
            response.payload = .ping(result)
        case .forgetBonds:
            bondCount = 0
        case .otaBegin, .otaEnd, .otaAbort:
            response.result = .unsupported
            response.message = "simulated board has no OTA"
        case .none:
            response.result = .unsupported
        case .some(let command):
            guard helloCompleted else {
                response.result = .invalidState
                response.message = "send Hello first"
                return response
            }
            handleAfterHello(command, response: &response)
        }
        return response
    }

    private mutating func handleAfterHello(_ command: NSBControlRequest.OneOf_Command, response: inout NSBControlResponse) {
        switch command {
        case .setTime(let setTime):
            epochOffsetMs = setTime.unixTimeMs &- uptimeMs
        case .configure(let configure):
            guard let resolved = Self.resolveChannels(role: configure.role, requested: configure.channels, profile: profile) else {
                response.result = .invalidArgument
                response.message = "no supported channel for role"
                return
            }
            configuration = configure
            channels = resolved
            channelIndex = 0
            if running { beginDwell(at: uptimeMs) }
            var result = NSBConfigureResult()
            result.channels = resolved
            result.role = configure.role
            response.payload = .configure(result)
        case .start:
            if !running {
                running = true
                beginDwell(at: uptimeMs)
                nextBLEWindowMs = uptimeMs + bleWindowMs
            }
        case .stop:
            running = false
            currentChannel = 0
        case .enterPairingMode:
            pairingMode = true
        default:
            response.result = .unsupported
        }
    }

    /// The phone went away: a new connection must send Hello again. The board
    /// keeps surveying, as real firmware does.
    mutating func linkDropped() {
        helloCompleted = false
    }

    /// The channels a board hops for a role, or nil when none are usable.
    static func resolveChannels(role: NSBRole, requested: [UInt32], profile: SimulatedBoardProfile) -> [UInt32]? {
        let supported = profile.supportedChannels
        let candidates: [UInt32]
        switch role {
        case .bleSniffer:
            return []
        case .fixedChannel:
            guard let channel = requested.first, supported.contains(channel) else { return nil }
            return [channel]
        case .band24:
            candidates = (requested.isEmpty ? WifiChannels.band24 : requested).filter { WifiChannels.band(of: $0) == .ghz24 }
        case .band5:
            candidates = (requested.isEmpty ? WifiChannels.band5 : requested).filter { WifiChannels.band(of: $0) == .ghz5 }
        default:
            candidates = requested.isEmpty ? supported : requested
        }
        let usable = candidates.filter(supported.contains)
        return usable.isEmpty ? nil : usable
    }

    // MARK: - Time

    /// Moves board time forward and returns what the board sent, in order.
    mutating func advance(byMs ms: UInt64) -> [Output] {
        let target = uptimeMs + ms
        var outputs: [Output] = []
        while true {
            var next = nextStatusMs
            if wifiActive { next = min(next, dwellEndMs) }
            if bleActive { next = min(next, nextBLEWindowMs) }
            guard next <= target else { break }
            uptimeMs = next
            if wifiActive, next == dwellEndMs {
                let records = wifiDwell(channel: currentChannel, durationMs: dwellMs(currentChannel), endMs: next)
                outputs += pack(records).map(Output.records)
                if configuration.rawFrames {
                    let frames = rawBeacons(for: records)
                    if !frames.isEmpty { outputs.append(.rawFrames(frames)) }
                }
                channelIndex = (channelIndex + 1) % max(channels.count, 1)
                beginDwell(at: next)
            }
            if bleActive, next == nextBLEWindowMs {
                outputs += pack(bleWindow(endMs: next)).map(Output.records)
                nextBLEWindowMs = next + bleWindowMs
            }
            if next == nextStatusMs {
                outputs.append(.status(status()))
                nextStatusMs = next + 1000
            }
        }
        uptimeMs = target
        return outputs
    }

    private var wifiActive: Bool { running && configuration.role != .bleSniffer && !channels.isEmpty }
    private var bleActive: Bool { running && configuration.ble }
    private var bleWindowMs: UInt64 { configuration.role == .bleSniffer ? Self.sniffWindowMs : Self.interleavePeriodMs }

    private mutating func beginDwell(at ms: UInt64) {
        guard !channels.isEmpty, configuration.role != .bleSniffer else {
            currentChannel = 0
            return
        }
        currentChannel = channels[channelIndex % channels.count]
        dwellEndMs = ms + UInt64(dwellMs(currentChannel))
    }

    func dwellMs(_ channel: UInt32) -> UInt32 {
        if WifiChannels.band(of: channel) == .ghz5 {
            return configuration.dwell5Ms > 0 ? configuration.dwell5Ms : Self.defaultDwell5Ms
        }
        return configuration.dwell24Ms > 0 ? configuration.dwell24Ms : Self.defaultDwell24Ms
    }

    mutating func countProduced(records: Int, frames: Int) {
        recordsThisSecond &+= UInt32(records)
        framesThisSecond &+= UInt32(frames)
    }

    private mutating func status() -> NSBBoardStatus {
        var status = NSBBoardStatus()
        status.boardTimeMs = boardTime(atUptime: uptimeMs)
        status.timeSynced = timeSynced
        status.state = running ? .surveying : .idle
        status.role = configuration.role
        status.currentChannel = currentChannel
        status.recordsPerSec = recordsThisSecond
        status.rxFramesPerSec = framesThisSecond
        status.ringFillPercent = ringFillPercent
        status.droppedRecords = droppedRecords
        status.uptimeMs = uptimeMs
        status.freeHeapBytes = 182_000 - UInt32.random(in: 0...6_000, using: &rng)
        status.minFreeHeapBytes = 161_000
        status.gpsState = .notPresent
        if let battery = profile.batteryMilliVolts {
            // About 1 mV per minute of drain, never below a nearly empty cell.
            status.batteryMv = max(3_300, battery - UInt32(uptimeMs / 60_000))
        }
        status.pairingMode = pairingMode
        status.bondCount = bondCount
        status.mtu = profile.mtu
        recordsThisSecond = 0
        framesThisSecond = 0
        rawFramesThisSecond = 0
        return status
    }

    // MARK: - Batching

    /// Splits records into batches of at most 12 records that each fit one
    /// notification at the board's MTU.
    func pack(_ records: [NSBRecord]) -> [NSBRecordBatch] {
        let limit = BoardFraming.maxMessageSize(maxPayload: Int(profile.mtu) - 3)
        var batches: [NSBRecordBatch] = []
        var current = NSBRecordBatch()
        current.timeSynced = timeSynced
        var size = timeSynced ? 2 : 0
        for record in records {
            let length = (try? record.serializedData())?.count ?? 0
            let encoded = 1 + Self.varintSize(length) + length
            guard encoded + (timeSynced ? 2 : 0) <= limit else { continue }  // Too large for any notification.
            if size + encoded > limit || current.records.count == Self.maxRecordsPerBatch, !current.records.isEmpty {
                batches.append(current)
                current.records = []
                size = timeSynced ? 2 : 0
            }
            current.records.append(record)
            size += encoded
        }
        if !current.records.isEmpty { batches.append(current) }
        return batches
    }

    private static func varintSize(_ value: Int) -> Int {
        var size = 1
        var rest = value >> 7
        while rest > 0 {
            size += 1
            rest >>= 7
        }
        return size
    }
}
