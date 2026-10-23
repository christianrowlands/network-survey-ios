import BoardKit
import BoardProtocol
import Foundation

let usage = """
    Usage: boardcli <command> [options]

    Commands:
      scan [--seconds N]              List boards advertising nearby (default 5 s).
      info <id>                       Read BoardInfo without pairing.
      pair <id>                       Pair (accept the system prompt), say Hello, remember the board.
      stream <id>... [--seconds N]    Survey and print per-type counts, records/s, gaps and drops.
             [--role auto|band24|band5|fixed:CH|ble] [--no-ble] [--verbose]
                                      (--role applies to every board streamed)
      forget <id>                     Tell the board to delete its bonds and forget it here.
      known                           List boards this Mac has paired with.

    <id> is a short ID (ABCD or NS-ABCD), a board ID (NS- and the 12-digit
    address) or the start of one, or the start of a scanned peripheral identifier.

    Options:
      --sim N        Use N simulated boards over the simulated Bluetooth layer
                     (--boards N is the same). With --sim, stream without an id
                     streams every simulated board.
      --seed S       Seed for simulated boards (default 1).
      --speed X      Simulated clock speed (default 1).
    """

let options: Options
do {
    options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("\(error)\n\n\(usage)\n".utf8))
    exit(2)
}

guard let command = options.command, command != "help" else {
    print(usage)
    exit(0)
}

let session = Session(options: options)
do {
    if command != "known" { try await session.waitForBluetooth() }
    switch command {
    case "scan": try await session.scan()
    case "info": try await session.info()
    case "pair": try await session.pair()
    case "stream": try await session.stream()
    case "forget": try await session.forget()
    case "known": await session.known()
    default:
        FileHandle.standardError.write(Data("Unknown command \(command)\n\n\(usage)\n".utf8))
        exit(2)
    }
    session.shutdown()
} catch {
    FileHandle.standardError.write(Data("Error: \(Explain.error(error))\n".utf8))
    session.shutdown()
    exit(1)
}

struct Options {
    var command: String?
    var ids: [String] = []
    var seconds: UInt64?
    var simulatedBoards: Int?
    var seed: UInt64 = 1
    var speed = 1.0
    var role: BoardRolePreference = .auto
    var ble = true
    var verbose = false

    struct ParseError: Error, CustomStringConvertible {
        var description: String
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        func value(_ name: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw ParseError(description: "\(name) needs a value") }
            return arguments[index]
        }
        func number<T: LosslessStringConvertible>(_ name: String) throws -> T {
            let text = try value(name)
            guard let parsed = T(text) else { throw ParseError(description: "\(name): not a number: \(text)") }
            return parsed
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--seconds": options.seconds = try number(argument)
            case "--sim", "--boards": options.simulatedBoards = min(max(try number(argument) as Int, 1), 8)
            case "--seed": options.seed = try number(argument)
            case "--speed": options.speed = try number(argument)
            case "--role": options.role = try role(value(argument))
            case "--no-ble": options.ble = false
            case "--verbose", "-v": options.verbose = true
            case "--help", "-h": options.command = "help"
            default:
                guard !argument.hasPrefix("--") else { throw ParseError(description: "unknown option \(argument)") }
                if options.command == nil { options.command = argument } else { options.ids.append(argument) }
            }
            index += 1
        }
        return options
    }

    static func role(_ text: String) throws -> BoardRolePreference {
        switch text.lowercased() {
        case "auto": return .auto
        case "band24", "2.4": return .band24
        case "band5", "5": return .band5
        case "ble", "sniffer": return .bleSniffer
        default:
            if text.hasPrefix("fixed:"), let channel = UInt32(text.dropFirst(6)) { return .fixedChannel(channel) }
            throw ParseError(description: "unknown role \(text)")
        }
    }
}
