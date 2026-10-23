/// What the app says about location access that needs the user, and the one
/// thing it offers to do about it. Every state points somewhere that works:
/// the system prompt, the app's own Settings page (only once it has a Location
/// row), or the system setting by name when no link reaches it.
struct LocationNotice: Equatable {
    enum Action: Equatable {
        /// Shows the system prompt (the app never asked).
        case allow
        /// Shows the system alert whose Settings button opens Location Services.
        case turnOnServices
        /// The app's page in Settings, which has a Location row once the app asked.
        case openSettings
        /// Precise location until the app is no longer in use.
        case usePrecise

        var title: String {
            switch self {
            case .allow: "Allow"
            case .turnOnServices: "Turn On"
            case .openSettings: "Open Settings"
            case .usePrecise: "Use precise location"
            }
        }
    }

    let id: String
    let symbol: String
    let level: StatusLevel
    let title: String
    let detail: String
    var action: Action?

    /// Nil when location works as it should.
    init?(_ access: LocationAccess) {
        switch access {
        case .ready:
            return nil
        case .notDetermined:
            self.init(id: "loc", symbol: "location", level: .pending, title: "Allow location",
                      detail: "Each record gets the iPhone's position, so coverage shows on the map.", action: .allow)
        case .servicesOff:
            // No public link opens the Location Services page, but asking for
            // access shows the system alert that does; the text says where it is too.
            self.init(id: "loc-services", symbol: "location.slash", level: .failing, title: "Location Services are off",
                      detail: "Turn on Location Services in Settings > Privacy & Security > Location Services. "
                          + "Records from a board can't be placed on the map without it.",
                      action: .turnOnServices)
        case .restricted:
            self.init(id: "loc-restricted", symbol: "location.slash", level: .failing,
                      title: "Location is restricted on this iPhone",
                      detail: "Screen Time or a device management profile blocks location access, "
                          + "so records from a board can't be placed on the map.")
        case .denied:
            self.init(id: "loc-denied", symbol: "location.slash", level: .failing, title: "Location access is off",
                      detail: "Turn on Location for Network Survey in Settings. "
                          + "Records from a board can't be placed on the map without it.",
                      action: .openSettings)
        case .approximate:
            self.init(id: "loc-approx", symbol: "location.circle", level: .held, title: "Precise location is off",
                      detail: "Positions are only approximate. Use precise location for this survey, "
                          + "or turn on Precise Location for Network Survey in Settings.",
                      action: .usePrecise)
        }
    }

    private init(id: String, symbol: String, level: StatusLevel, title: String, detail: String, action: Action? = nil) {
        self.id = id
        self.symbol = symbol
        self.level = level
        self.title = title
        self.detail = detail
        self.action = action
    }
}
