import Foundation
import Synchronization

/// A private mosquitto broker on a free local port, plus a mosquitto_sub on
/// every topic that counts messages per topic.
final class MQTTBroker: Sendable {
    static let readyTopic = "e2e-harness/ready"

    let port: Int
    private let broker: Process
    private let subscriber: Process
    private let directory: URL
    private let output = SubscriberOutput()

    init(tally: Tally, mosquitto: String, tools: String) throws {
        port = try FreePort.find()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-harness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = directory.appendingPathComponent("mosquitto.conf")
        // No limits on queued or in-flight messages: the subscriber must see every one.
        try """
        listener \(port) 127.0.0.1
        allow_anonymous true
        persistence false
        max_queued_messages 0
        max_inflight_messages 0
        log_type error

        """.write(to: config, atomically: true, encoding: .utf8)
        broker = Process()
        broker.executableURL = URL(fileURLWithPath: mosquitto)
        broker.arguments = ["-c", config.path]
        try broker.run()

        subscriber = Process()
        subscriber.executableURL = URL(fileURLWithPath: tools).appendingPathComponent("mosquitto_sub")
        subscriber.arguments = ["-h", "127.0.0.1", "-p", String(port), "-t", "#", "-v", "-q", "1", "-i", "ns-e2e-harness"]
        let pipe = Pipe()
        subscriber.standardOutput = pipe
        let output = output
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            let lines = output.buffer.withLock { buffer -> [Data] in
                buffer.append(chunk)
                var lines: [Data] = []
                while let newline = buffer.firstIndex(of: 0x0A) {
                    lines.append(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
                return lines
            }
            for line in lines { Self.count(line, tally: tally, output: output) }
        }
        try FreePort.waitUntilListening(port)
        try subscriber.run()
        try waitUntilSubscribed(tools: tools)
    }

    /// `topic payload` lines; payloads are single-line NS Messaging JSON.
    private static func count(_ line: Data, tally: Tally, output: SubscriberOutput) {
        let text = String(decoding: line, as: UTF8.self)
        guard let space = text.firstIndex(of: " ") else { return }
        let topic = String(text[..<space])
        if topic == readyTopic {
            output.readySeen.withLock { $0 = true }
            return
        }
        let payload = Data(text[text.index(after: space)...].utf8)
        guard let json = try? JSONSerialization.jsonObject(with: payload), let fields = RecordFields(json: json) else {
            tally.update { $0.mqttUnparsed += 1 }
            return
        }
        tally.update { $0.mqtt[topic, default: ChannelTally()].add(fields) }
    }

    /// Publishes to the ready topic until the subscriber hears it.
    private func waitUntilSubscribed(tools: String) throws {
        for _ in 0..<50 {
            let publish = Process()
            publish.executableURL = URL(fileURLWithPath: tools).appendingPathComponent("mosquitto_pub")
            publish.arguments = ["-h", "127.0.0.1", "-p", String(port), "-t", Self.readyTopic, "-m", "1"]
            try? publish.run()
            publish.waitUntilExit()
            Thread.sleep(forTimeInterval: 0.2)
            if output.readySeen.withLock({ $0 }) { return }
        }
        throw HarnessError("mosquitto_sub never received the ready message")
    }

    func stop() {
        if subscriber.isRunning { subscriber.terminate() }
        if broker.isRunning { broker.terminate() }
        subscriber.waitUntilExit()
        broker.waitUntilExit()
        try? FileManager.default.removeItem(at: directory)
    }
}

enum FreePort {
    /// Binds port 0 on 127.0.0.1 and returns the port the system picked.
    static func find() throws -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw HarnessError("socket() failed") }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddr in
                bind(socket, sockaddr, length) == 0 && getsockname(socket, sockaddr, &length) == 0
            }
        }
        guard bound else { throw HarnessError("Could not find a free port") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

extension FreePort {
    /// Waits up to 5 s until something accepts connections on the port.
    static func waitUntilListening(_ port: Int) throws {
        for _ in 0..<50 {
            let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = UInt16(port).bigEndian
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            close(socket)
            if connected { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw HarnessError("Nothing listens on port \(port)")
    }
}

/// mosquitto_sub output not yet split into lines, and whether the ready message arrived.
final class SubscriberOutput: Sendable {
    let buffer = Mutex(Data())
    let readySeen = Mutex(false)
}
