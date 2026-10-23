import Foundation

/// Limits from proto/ns_board.options that matter when the app sends to a board.
/// A board cannot decode a ControlRequest that exceeds them.
public enum BoardLimits {
    public static let appVersionBytes = 31
    public static let configureChannels = 64
    public static let controlRequestBytes = 512

    /// Cuts `text` to at most `maxBytes` UTF-8 bytes without splitting a character.
    public static func truncateUTF8(_ text: String, maxBytes: Int) -> String {
        var result = ""
        var used = 0
        for character in text {
            let size = character.utf8.count
            guard used + size <= maxBytes else { break }
            result.append(character)
            used += size
        }
        return result
    }
}

extension NSBHello {
    /// A Hello for the protocol version in this package, within the board's limits.
    public static func current(appVersion: String) -> NSBHello {
        .with {
            $0.protocolMajor = UInt32(NSBProtocolVersion.major.rawValue)
            $0.protocolMinor = UInt32(NSBProtocolVersion.minor.rawValue)
            $0.appVersion = BoardLimits.truncateUTF8(appVersion, maxBytes: BoardLimits.appVersionBytes)
        }
    }
}

extension NSBBleObservation {
    /// The advertised name decoded leniently: invalid UTF-8 becomes U+FFFD.
    public var localNameText: String {
        String(decoding: localName, as: UTF8.self)
    }
}
