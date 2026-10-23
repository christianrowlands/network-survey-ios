import BoardKit
import BoardProtocol
import Foundation

/// One CLI run: the transport (CoreBluetooth or simulated) and a BoardManager.
@MainActor
final class Session {
    let options: Options
    let transport: BLEBoardTransport
    let simulated: SimulatedBLECentral?
    let manager: BoardManager

    init(options: Options) {
        self.options = options
        if let count = options.simulatedBoards {
            let central = SimulatedBLECentral(boardCount: count, seed: options.seed)
            central.startClock(speed: options.speed)
            simulated = central
            transport = BLEBoardTransport(central: central)
        } else {
            simulated = nil
            // The embedded Info.plist names the bundle, so standard defaults are boardcli's own.
            transport = .coreBluetooth(store: UserDefaultsKnownBoardStore(defaults: .standard))
        }
        manager = BoardManager(transport: transport, appVersion: "boardcli")
    }

    func shutdown() {
        simulated?.shutdown()
    }

    func waitForBluetooth() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            switch transport.central.powerState {
            case .poweredOn: return
            case .unauthorized, .unsupported, .poweredOff: throw BoardTransportError.bluetoothUnavailable(transport.central.powerState.rawValue)
            default: try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw BoardTransportError.bluetoothUnavailable(transport.central.powerState.rawValue)
    }

    // MARK: - Commands

    func scan() async throws {
        await manager.startScanning()
        let seconds = options.seconds ?? 5
        var announced = Set<BoardID>()
        for _ in 0..<(seconds * 4) {
            try await Task.sleep(for: .milliseconds(250))
            for board in manager.discovered where announced.insert(board.id).inserted {
                print("found \(board.name)  \(board.id)")
            }
        }
        await manager.stopScanning()
        print("")
        print(Explain.pad("Name", 10) + Explain.pad("RSSI", 6) + Explain.pad("Model", 24) + Explain.pad("Proto", 6) + "Flags  Identifier")
        for board in manager.discovered {
            print(
                Explain.pad(board.name, 10) + Explain.pad("\(board.rssi)", 6) + Explain.pad("\(board.model)", 24)
                    + Explain.pad("\(board.protocolMajor)", 6) + Explain.pad(Explain.flags(board), 7) + "\(board.id)"
            )
        }
        if manager.discovered.isEmpty { print("No boards found.") }
    }

    func info() async throws {
        let id = try await resolve(singleID())
        let info = try await transport.readInfo(id)
        print(Explain.info(info, id: BoardID(info: info) ?? id))
    }

    func pair() async throws {
        let scanned = try await resolve(singleID())
        print("Connecting. Accept the pairing prompt if one appears.")
        let id = try await manager.connect(scanned)
        let state = manager.boards[id]
        print("Paired and ready: \(state?.info.map { "NS-\($0.shortID)" } ?? "\(id)")  board ID \(id)")
        if case .compatible(let version)? = state?.compatibility { print("Firmware \(version), protocol compatible.") }
        print("Max write without response: \(await transport.maximumOTAWriteLength(for: id) ?? 0) bytes")
        await manager.disconnect(id)
    }

    func forget() async throws {
        let id = try await resolve(singleID())
        // Connecting an unknown board would pair it just to forget it.
        if await transport.knownBoards().contains(where: { $0.id == id }) {
            do {
                try await transport.connect(id)
            } catch {
                print("Could not connect (\(Explain.error(error))); forgetting it on this Mac only.")
            }
        } else {
            print("This Mac has not paired with the board; nothing to tell it.")
        }
        let confirmed = await manager.forget(id)
        print(confirmed ? "The board deleted its bonds." : "The board was not told (not connected).")
        print("Also remove the board in System Settings > Bluetooth before pairing again.")
    }

    func known() async {
        let boards = await transport.knownBoards()
        if boards.isEmpty { print("No known boards.") }
        for board in boards {
            print("\(Explain.pad(board.name, 10))\(Explain.pad("\(board.model)", 24))last connected \(board.lastConnected)  \(board.id)")
        }
    }

    func stream() async throws {
        var ids: [BoardID] = []
        if options.ids.isEmpty, let simulated {
            ids = simulated.peripheralIDs.prefix(BoardManager.maxBoards).map { $0 }  // As a scan shows them.
        } else {
            guard !options.ids.isEmpty else { throw Options.ParseError(description: "stream needs at least one board id") }
            for text in options.ids { ids.append(try await resolve(text)) }
        }
        for index in ids.indices {
            ids[index] = try await manager.connect(ids[index])  // The stable ID from now on.
            await manager.setRole(options.role, for: ids[index])
        }
        var capture = SurveyCapture()
        capture.ble = options.ble
        let plan = try await manager.startSurvey(capture)
        for id in ids {
            guard let assignment = plan[id] else { continue }
            print("\(name(id)): \(assignment.role)\(assignment.ble ? " + BLE" : "")  channels \(assignment.channels.map(String.init).joined(separator: ","))")
        }
        let printer = options.verbose ? verbosePrinter() : nil
        let seconds = options.seconds ?? 10
        let started = ContinuousClock.now
        var last = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0) })
        print(Explain.streamHeader)
        for second in 1...Int(max(seconds, 1)) {
            try await Task.sleep(until: started + .seconds(Int64(second)))
            for id in ids {
                let counters = manager.counters(for: id)
                print(Explain.streamLine(second: second, name: name(id), counters: counters, perSecond: counters.records - last[id, default: 0], status: manager.boards[id]?.status))
                last[id] = counters.records
            }
        }
        printer?.cancel()
        await manager.stopSurvey()
        let elapsed = (ContinuousClock.now - started)
        print("\nTotals over \(Explain.seconds(elapsed)):")
        for id in ids {
            print(Explain.summary(name: name(id), counters: manager.counters(for: id), elapsed: elapsed))
        }
        for id in ids { await manager.disconnect(id) }
    }

    // MARK: - Helpers

    private func singleID() throws -> String {
        if let id = options.ids.first { return id }
        if let simulated, let first = simulated.peripheralIDs.first { return first.description }
        throw Options.ParseError(description: "this command needs a board id")
    }

    private func name(_ id: BoardID) -> String {
        manager.boards[id]?.info.map { "NS-\($0.shortID)" } ?? String(id.description.prefix(8))
    }

    /// Finds a board by short ID or identifier prefix: known boards first, then a scan.
    func resolve(_ text: String) async throws -> BoardID {
        let key = text.uppercased().replacingOccurrences(of: "NS-", with: "")
        func matches(_ shortID: String, _ id: BoardID) -> Bool {
            shortID.uppercased() == key || id.description.uppercased().replacingOccurrences(of: "NS-", with: "").hasPrefix(key)
        }
        if let board = await transport.knownBoards().first(where: { matches($0.shortID, $0.id) }) { return board.id }
        await manager.startScanning()
        defer { Task { await manager.stopScanning() } }
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if let board = manager.discovered.first(where: { matches($0.shortID, $0.id) }) { return board.id }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw Options.ParseError(description: "no board \(text) found within 10 seconds")
    }

    private func verbosePrinter() -> Task<Void, Never> {
        let records = manager.records()
        let names = Dictionary(uniqueKeysWithValues: manager.boards.compactMap { id, state in state.info.map { (id, "NS-\($0.shortID)") } })
        return Task.detached {
            for await envelope in records {
                print("\(names[envelope.boardID] ?? "?") \(RecordLine.describe(envelope.record))")
            }
        }
    }
}
