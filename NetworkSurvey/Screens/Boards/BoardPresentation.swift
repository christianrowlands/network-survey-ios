import BoardKit
import BoardProtocol
import Foundation

/// Board battery from the reported cell voltage (a single LiPo cell).
enum BoardBattery {
    /// Open-circuit voltage to charge, piecewise linear: 4.20 V full, 3.30 V empty.
    private static let curve: [(mv: Double, percent: Double)] = [
        (3300, 0), (3600, 10), (3700, 25), (3750, 40), (3800, 50), (3900, 65), (4000, 80), (4100, 92), (4200, 100),
    ]

    static func percent(millivolts: Int) -> Int {
        let mv = Double(millivolts)
        guard mv > curve[0].mv else { return 0 }
        for (low, high) in zip(curve, curve.dropFirst()) where mv <= high.mv {
            let fraction = (mv - low.mv) / (high.mv - low.mv)
            return Int((low.percent + fraction * (high.percent - low.percent)).rounded())
        }
        return 100
    }

    static func percent(_ status: NSBBoardStatus) -> Int? {
        status.hasBatteryMv ? percent(millivolts: Int(status.batteryMv)) : nil
    }

    /// An SF Symbol for the level.
    static func symbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

extension BoardRolePreference {
    /// Every role the picker offers for a board with these bands.
    static func choices(bands: [NSBBand]) -> [BoardRolePreference] {
        var roles: [BoardRolePreference] = [.auto]
        if bands.contains(.ghz5) { roles += [.band24, .band5] }
        roles.append(.fixedChannel(6))
        roles.append(.bleSniffer)
        return roles
    }

    var title: String {
        switch self {
        case .auto: "Automatic"
        case .band24: "2.4 GHz only"
        case .band5: "5 GHz only"
        case .fixedChannel: "One channel"
        case .bleSniffer: "Bluetooth only"
        }
    }

    var explanation: String {
        switch self {
        case .auto: "Shares the channels with your other boards. Recommended."
        case .band24: "Hops the 2.4 GHz channels."
        case .band5: "Hops the 5 GHz channels."
        case .fixedChannel(let channel): "Stays on channel \(channel), so nothing on it is missed."
        case .bleSniffer: "Listens to Bluetooth all the time, no Wi-Fi."
        }
    }

    /// Same kind of role, ignoring the channel number.
    func sameKind(as other: BoardRolePreference) -> Bool {
        switch (self, other) {
        case (.auto, .auto), (.band24, .band24), (.band5, .band5), (.bleSniffer, .bleSniffer), (.fixedChannel, .fixedChannel): true
        default: false
        }
    }
}

enum BoardText {
    static func name(shortID: String) -> String { "NS-\(shortID)" }

    static func model(_ info: NSBBoardInfo) -> String {
        if !info.modelName.isEmpty { return info.modelName }
        return switch info.boardModel {
        case .esp32C5Devkitc1: "ESP32-C5-DevKitC-1"
        case .xiaoEsp32C5: "XIAO ESP32-C5"
        case .esp32C6Generic: "ESP32-C6"
        case .esp32S3Generic: "ESP32-S3"
        case .esp32C3Generic: "ESP32-C3"
        default: "Unknown board"
        }
    }

    static func bands(_ bands: [NSBBand]) -> String {
        let names = bands.compactMap { band -> String? in
            switch band {
            case .ghz24: "2.4 GHz"
            case .ghz5: "5 GHz"
            case .ghz6: "6 GHz"
            default: nil
            }
        }
        return names.isEmpty ? "No Wi-Fi" : names.joined(separator: " and ")
    }

    /// What the board does in the running survey: "Auto · 19 channels", "Bluetooth only".
    static func assignment(_ assignment: BoardAssignment?, status: NSBBoardStatus?) -> String? {
        guard let assignment else { return nil }
        if assignment.role == .bleSniffer { return assignment.automaticSniffer ? "Bluetooth (automatic)" : "Bluetooth only" }
        if assignment.isIdle { return "Idle" }
        let role = switch assignment.role {
        case .band24: "2.4 GHz"
        case .band5: "5 GHz"
        case .fixedChannel: "Channel"
        default: "Auto"
        }
        if assignment.channels.count == 1 { return "\(role) · ch \(assignment.channels[0])" }
        let current = status.map(\.currentChannel).flatMap { $0 > 0 ? " · now \($0)" : nil } ?? ""
        return "\(role) · \(assignment.channels.count) ch\(current)"
    }

    /// The connection line under a board's name.
    static func connection(_ state: BoardManager.BoardState?) -> String {
        guard let state else { return "Not connected" }
        if let issue = state.issue {
            switch issue {
            case .bondMissing: return "Pairing lost"
            case .pairingRejected: return "Pairing refused"
            case .incompatible: return "Needs a firmware update"
            case .configureFailed: return "Could not start"
            }
        }
        if let reconnect = state.reconnect {
            return reconnect.attempt > 1 ? "Reconnecting (try \(reconnect.attempt))" : "Reconnecting"
        }
        switch state.connection {
        case .connecting: return "Connecting"
        case .connected: return state.isReady ? "Connected" : "Setting up"
        case .disconnected(let reason):
            switch reason {
            case .linkLost: return "Out of range"
            case .bondMissing: return "Pairing lost"
            case .pairingRejected: return "Pairing refused"
            case .failed: return "Could not connect"
            case .requested, nil: return "Not connected"
            }
        }
    }

    static func issueMessage(_ issue: BoardIssue, name: String) -> String {
        switch issue {
        case .bondMissing:
            "\(name) no longer has this iPhone's pairing. Open Settings > Bluetooth, tap the info button next to \(name), choose Forget This Device, then connect again."
        case .pairingRejected:
            "Pairing did not finish. If \(name) is paired with another phone, hold its BOOT button for 3 seconds until the light blinks fast, then connect again."
        case .incompatible(let reason):
            reason
        case .configureFailed(let reason):
            "The board refused its survey settings: \(reason)"
        }
    }
}
