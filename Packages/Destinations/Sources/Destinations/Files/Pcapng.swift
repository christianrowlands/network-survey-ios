import BoardProtocol
import Foundation

/// pcapng blocks (little-endian): a Section Header, one Interface Description
/// per board (link type 127, IEEE 802.11 with radiotap) and an Enhanced Packet
/// per frame.
enum Pcapng {
    static let linkTypeRadiotap: UInt16 = 127

    static func sectionHeader(application: String) -> Data {
        var body = Data()
        body.appendLE(UInt32(0x1A2B_3C4D)) // byte-order magic
        body.appendLE(UInt16(1)) // version 1.0
        body.appendLE(UInt16(0))
        body.appendLE(UInt64.max) // section length unknown
        body.append(options([(4, Data(application.utf8))])) // shb_userappl
        return block(type: 0x0A0D_0D0A, body: body)
    }

    static func interfaceDescription(name: String) -> Data {
        var body = Data()
        body.appendLE(linkTypeRadiotap)
        body.appendLE(UInt16(0))
        body.appendLE(UInt32(0)) // snaplen: no limit
        body.append(options([(2, Data(name.utf8)), (9, Data([6]))])) // if_name, if_tsresol = microseconds
        return block(type: 1, body: body)
    }

    static func enhancedPacket(interface: UInt32, timestamp: Date, packet: Data, originalLength: Int) -> Data {
        let micros = UInt64(max(0, (timestamp.timeIntervalSince1970 * 1_000_000).rounded()))
        var body = Data()
        body.appendLE(interface)
        body.appendLE(UInt32(truncatingIfNeeded: micros >> 32))
        body.appendLE(UInt32(truncatingIfNeeded: micros))
        body.appendLE(UInt32(packet.count))
        body.appendLE(UInt32(max(originalLength, packet.count)))
        body.append(packet)
        body.append(Data(count: padding(packet.count)))
        return block(type: 6, body: body)
    }

    private static func block(type: UInt32, body: Data) -> Data {
        let total = UInt32(12 + body.count)
        var data = Data()
        data.appendLE(type)
        data.appendLE(total)
        data.append(body)
        data.appendLE(total)
        return data
    }

    private static func options(_ list: [(UInt16, Data)]) -> Data {
        var data = Data()
        for (code, value) in list {
            data.appendLE(code)
            data.appendLE(UInt16(value.count))
            data.append(value)
            data.append(Data(count: padding(value.count)))
        }
        data.appendLE(UInt32(0)) // opt_endofopt
        return data
    }

    static func padding(_ count: Int) -> Int { (4 - count % 4) % 4 }
}

/// A radiotap header made from the board's receive metadata.
enum Radiotap {
    private static let cckRates: Set<UInt32> = [2, 4, 11, 22]

    static func header(for frame: NSBRawFrame) -> Data {
        var present: UInt32 = 0
        var fields = Data()
        func align(_ size: Int) {
            // Offsets count from the start of the header, which has 8 fixed bytes.
            while (8 + fields.count) % size != 0 { fields.append(0) }
        }

        present |= 1 << 1 // Flags
        fields.append(frame.fcsIncluded ? 0x10 : 0x00)
        let legacyRate = frame.phy == .legacy || frame.phy == .unspecified ? frame.rate500Kbps : 0
        if legacyRate != 0 {
            present |= 1 << 2
            fields.append(UInt8(truncatingIfNeeded: legacyRate))
        }
        if frame.frequencyMhz != 0 {
            present |= 1 << 3
            align(2)
            fields.appendLE(UInt16(truncatingIfNeeded: frame.frequencyMhz))
            var flags: UInt16
            switch frame.band {
            case .ghz5, .ghz6: flags = 0x0100 | 0x0040
            default: flags = 0x0080 | (cckRates.contains(legacyRate) ? 0x0020 : 0x0040)
            }
            if frame.band == .unspecified && frame.frequencyMhz > 5000 { flags = 0x0140 }
            fields.appendLE(flags)
        }
        present |= 1 << 5 // dBm antenna signal
        fields.append(UInt8(bitPattern: Int8(clamping: frame.rssi)))
        if frame.hasNoiseFloorDbm {
            present |= 1 << 6
            fields.append(UInt8(bitPattern: Int8(clamping: frame.noiseFloorDbm)))
        }
        if frame.phy == .ht && frame.hasMcs {
            present |= 1 << 19 // MCS: known = index, flags, index
            fields.append(contentsOf: [0x02, 0x00, UInt8(truncatingIfNeeded: frame.mcs)])
        }

        var header = Data([0, 0])
        header.appendLE(UInt16(8 + fields.count))
        header.appendLE(present)
        header.append(fields)
        return header
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

/// Writes raw frames to one pcapng file per session, with one interface per
/// board, named by its board ID.
public actor PcapDestination: Destination {
    public nonisolated let kind = DestinationKind.pcap

    private var session: SessionInfo?
    private var url: URL?
    private var handle: FileHandle?
    private var interfaces: [String: UInt32] = [:]
    private var bytes: Int64 = 0
    private var recordsAccepted = 0
    private var lastError: String?

    public init() {}

    public func start(_ session: SessionInfo) async throws {
        try FileManager.default.createDirectory(at: session.directory, withIntermediateDirectories: true)
        self.session = session
        interfaces = [:]
        bytes = 0
        recordsAccepted = 0
        lastError = nil
        url = nil
    }

    public func accept(_ records: [SurveyRecord]) async {
        var output = Data()
        for record in records {
            guard case .rawFrame(let frame, let timestamp) = record.kind else { continue }
            if handle == nil {
                guard open() else { return }
            }
            let interface: UInt32
            if let known = interfaces[record.boardID] {
                interface = known
            } else {
                interface = UInt32(interfaces.count)
                interfaces[record.boardID] = interface
                output.append(Pcapng.interfaceDescription(name: record.boardID.isEmpty ? "board" : record.boardID))
            }
            let radiotap = Radiotap.header(for: frame)
            output.append(Pcapng.enhancedPacket(
                interface: interface, timestamp: timestamp, packet: radiotap + frame.data,
                originalLength: radiotap.count + Int(frame.origLen)
            ))
            recordsAccepted += 1
        }
        write(output)
    }

    public func stop() async {
        try? handle?.close()
        handle = nil
        session = nil
    }

    public func snapshot() async -> DestinationSnapshot {
        var snapshot = DestinationSnapshot(status: lastError.map { .error($0) } ?? (session == nil ? .off : .running))
        snapshot.recordsAccepted = recordsAccepted
        snapshot.lastError = lastError
        if let url { snapshot.files = [.init(url: url, bytes: bytes)] }
        return snapshot
    }

    private func open() -> Bool {
        guard let session else { return false }
        let url = FileNaming.uniqueURL(in: session.directory, prefix: "craxiom-wifi-raw-", session: session, extension: "pcapng")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            lastError = "Could not create \(url.lastPathComponent)"
            return false
        }
        self.url = url
        self.handle = handle
        write(Pcapng.sectionHeader(application: "Network Survey iOS \(session.appVersion)"))
        return true
    }

    private func write(_ data: Data) {
        guard !data.isEmpty, let handle else { return }
        do {
            try handle.write(contentsOf: data)
            bytes += Int64(data.count)
        } catch {
            lastError = error.localizedDescription
        }
    }
}
