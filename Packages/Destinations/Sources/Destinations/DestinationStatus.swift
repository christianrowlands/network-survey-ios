/// Where survey records go (files, MQTT, gRPC, NS Analytics). The `Destination`
/// protocol and its implementations are added by later work.
public enum DestinationStatus: Equatable, Sendable {
    case off
    case starting
    case running
    case error(String)

    public var isActive: Bool {
        switch self {
        case .starting, .running: true
        case .off, .error: false
        }
    }
}
