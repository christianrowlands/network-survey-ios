import Dispatch
import Foundation

// e2e-harness [--ports-file <path>]
//
// Starts a mosquitto broker with a subscriber, an NS Messaging gRPC server and
// an HTTP server (NS Analytics stub plus /e2e/ control endpoints) on free
// local ports, prints {"httpPort":..,"mqttPort":..,"grpcPort":..} and writes
// it to the ports file, then runs until interrupted (SIGINT or SIGTERM).

var arguments = CommandLine.arguments.dropFirst()
var portsFile: String?
while let argument = arguments.popFirst() {
    switch argument {
    case "--ports-file": portsFile = arguments.popFirst()
    default:
        FileHandle.standardError.write(Data("usage: e2e-harness [--ports-file <path>]\n".utf8))
        exit(2)
    }
}

guard let mosquitto = Tools.find("mosquitto") ?? ["/opt/homebrew/sbin/mosquitto", "/usr/local/sbin/mosquitto"]
    .first(where: FileManager.default.isExecutableFile(atPath:)),
    let subscriberTool = Tools.find("mosquitto_sub") else {
    FileHandle.standardError.write(Data("e2e-harness: mosquitto and mosquitto_sub are needed (brew install mosquitto)\n".utf8))
    exit(1)
}

let tally = Tally()
let broker: MQTTBroker
let grpc: SurveyGRPCServer
let http: HTTPServer
do {
    broker = try MQTTBroker(
        tally: tally, mosquitto: mosquitto, tools: URL(fileURLWithPath: subscriberTool).deletingLastPathComponent().path
    )
    grpc = try await SurveyGRPCServer(tally: tally)
    let routes = RoutesBox()
    http = try await HTTPServer { await routes.value?.handle($0) ?? .json(["error": "starting"], status: .serviceUnavailable) }
    let ports = ["httpPort": http.port, "mqttPort": broker.port, "grpcPort": grpc.port]
    routes.set(Routes(tally: tally, ports: ports))
    let json = try JSONSerialization.data(withJSONObject: ports, options: [.sortedKeys])
    if let portsFile { try json.write(to: URL(fileURLWithPath: portsFile)) }
    print(String(decoding: json, as: UTF8.self))
    fflush(stdout)
} catch {
    FileHandle.standardError.write(Data("e2e-harness: \(error)\n".utf8))
    exit(1)
}

let stop: @Sendable () -> Void = {
    broker.stop()
    grpc.stop()
    http.stop()
    exit(0)
}
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sources = [SIGINT, SIGTERM].map { number in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
    source.setEventHandler(handler: stop)
    source.resume()
    return source
}
while true {
    try await Task.sleep(for: .seconds(3600))
}
