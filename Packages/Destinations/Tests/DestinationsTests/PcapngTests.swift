import BoardProtocol
import Foundation
import Testing
@testable import Destinations

@Suite("pcapng with radiotap")
struct PcapngTests {
    /// A beacon for SSID ExampleNet from BSSID 02:00:5e:00:00:01.
    static let beacon: [UInt8] = [
        0x80, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x02, 0x00, 0x5E, 0x00, 0x00, 0x01,
        0x02, 0x00, 0x5E, 0x00, 0x00, 0x01, 0x00, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0x64, 0x00, 0x01, 0x04,
        0x00, 0x0A, 0x45, 0x78, 0x61, 0x6D, 0x70, 0x6C, 0x65, 0x4E, 0x65, 0x74,
        0x01, 0x04, 0x82, 0x84, 0x8B, 0x96, 0x03, 0x01, 0x06,
    ]

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    static var frames: [SurveyRecord] {
        let legacy = NSBRawFrame.with {
            $0.channel = 6
            $0.frequencyMhz = 2437
            $0.band = .ghz24
            $0.rssi = -52
            $0.noiseFloorDbm = -95
            $0.phy = .legacy
            $0.rate500Kbps = 2
            $0.origLen = UInt32(beacon.count)
            $0.data = Data(beacon)
        }
        var withFCS = beacon
        withFCS.append(contentsOf: withUnsafeBytes(of: crc32(beacon).littleEndian, Array.init))
        let ht = NSBRawFrame.with {
            $0.channel = 36
            $0.frequencyMhz = 5180
            $0.band = .ghz5
            $0.rssi = -60
            $0.phy = .ht
            $0.mcs = 7
            $0.fcsIncluded = true
            $0.origLen = UInt32(withFCS.count + 100)
            $0.data = Data(withFCS)
        }
        return [
            SurveyRecord(boardID: "NS-1A2B", kind: .rawFrame(legacy, timestamp: Date(timeIntervalSince1970: 1_792_000_987.123456))),
            SurveyRecord(boardID: "NS-3C4D", kind: .rawFrame(ht, timestamp: Date(timeIntervalSince1970: 1_792_000_988.5))),
            SurveyRecord(boardID: "NS-1A2B", kind: .rawFrame(legacy, timestamp: Date(timeIntervalSince1970: 1_792_000_989))),
        ]
    }

    @Test("Radiotap fields are aligned and flagged")
    func radiotap() {
        guard case .rawFrame(let legacy, _) = Self.frames[0].kind, case .rawFrame(let ht, _) = Self.frames[1].kind else { return }
        // v0, len 16, present Flags|Rate|Channel|Signal|Noise, flags, rate, pad, channel, signal, noise
        #expect([UInt8](Radiotap.header(for: legacy)) == [
            0, 0, 16, 0, 0x6E, 0, 0, 0, 0x00, 0x02, 0x85, 0x09, 0xA0, 0x00, 0xCC, 0xA1,
        ])
        // Flags (FCS), pad, channel 5180 OFDM 5 GHz, signal, MCS known=index, flags, 7
        #expect([UInt8](Radiotap.header(for: ht)) == [
            0, 0, 18, 0, 0x2A, 0, 0x08, 0, 0x10, 0x00, 0x3C, 0x14, 0x40, 0x01, 0xC4, 0x02, 0x00, 0x07,
        ])
    }

    @Test("The file has a section header, one interface per board and a packet per frame")
    func blocks() async throws {
        let directory = Samples.tempDirectory()
        let destination = PcapDestination()
        try await destination.start(Samples.session(directory))
        await destination.accept(Self.frames + [Samples.apRecord()])
        let snapshot = await destination.snapshot()
        #expect(snapshot.recordsAccepted == 3)
        await destination.stop()
        let url = directory.appendingPathComponent("craxiom-wifi-raw-20261014-180300.pcapng")
        let bytes = [UInt8](try Data(contentsOf: url))
        #expect(snapshot.files.first?.bytes == Int64(bytes.count))

        var types: [UInt32] = []
        var offset = 0
        func u32(_ at: Int) -> UInt32 { UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24 }
        while offset < bytes.count {
            let length = Int(u32(offset + 4))
            #expect(length % 4 == 0)
            #expect(u32(offset + length - 4) == UInt32(length))
            types.append(u32(offset))
            if u32(offset) == 6 {
                let micros = UInt64(u32(offset + 12)) << 32 | UInt64(u32(offset + 16))
                #expect(micros % 1_000_000 != 0 || micros == 1_792_000_989_000_000)
            }
            offset += length
        }
        #expect(offset == bytes.count)
        #expect(types == [0x0A0D0D0A, 1, 6, 1, 6, 6])
    }

    #if os(macOS)
    /// tshark prints the SSID field as hex: "ExampleNet".
    static let ssidHex = "4578616d706c654e6574"

    static func tool(_ name: String) -> String? {
        ["/Applications/Wireshark.app/Contents/MacOS/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self)
    }

    @Test("tshark and capinfos read the file", .enabled(if: tool("tshark") != nil && tool("capinfos") != nil))
    func wireshark() async throws {
        let directory = Samples.tempDirectory()
        let destination = PcapDestination()
        try await destination.start(Samples.session(directory))
        await destination.accept(Self.frames)
        await destination.stop()
        let path = directory.appendingPathComponent("craxiom-wifi-raw-20261014-180300.pcapng").path

        let info = try Self.run(Self.tool("capinfos")!, ["-M", path])
        #expect(info.contains("Number of packets:   3") || info.contains("Number of packets = 3"))
        #expect(info.contains("IEEE 802.11 plus radiotap radio header"))
        #expect(info.contains("Number of interfaces in file: 2"))

        let fields = try Self.run(Self.tool("tshark")!, [
            "-r", path, "-T", "fields", "-E", "separator=|", "-e", "frame.interface_name", "-e", "radiotap.dbm_antsignal",
            "-e", "radiotap.dbm_antnoise", "-e", "radiotap.channel.freq", "-e", "radiotap.datarate", "-e", "radiotap.mcs.index",
            "-e", "wlan.ssid", "-e", "wlan.bssid", "-e", "frame.time_epoch",
        ]).split(separator: "\n").map { $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init) }
        #expect(fields.count == 3)
        #expect(Array(fields[0].prefix(8)) == ["NS-1A2B", "-52", "-95", "2437", "1", "", Self.ssidHex, "02:00:5e:00:00:01"])
        #expect(fields[0][8].hasPrefix("1792000987.123456"))
        #expect(Array(fields[1].prefix(8)) == ["NS-3C4D", "-60", "", "5180", "", "7", Self.ssidHex, "02:00:5e:00:00:01"])
        #expect(fields[2][0] == "NS-1A2B")

        // No malformed packets or expert errors.
        let expert = try Self.run(Self.tool("tshark")!, ["-r", path, "-Y", "_ws.malformed || _ws.expert.severity >= error"])
        #expect(expert.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    #endif
}
