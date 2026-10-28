import Foundation

/// Launch arguments for UI tests, screenshots and demos, for example
/// `-NSUITesting YES -NSDemoBoards 2 -NSAutoStartSurvey YES`.
struct LaunchOptions {
    /// An isolated app: settings, survey database and Keychain items in memory,
    /// the demo board shown, Bluetooth never touched.
    var uiTesting = false
    /// Number of simulated boards behind the demo board (1 to 4).
    var demoBoards = 1
    var demoSeed: UInt64 = 1
    /// Connects the demo board(s) at launch.
    var autoConnectDemo = false
    /// Connects the demo board(s) and starts a survey at launch.
    var autoStartSurvey = false
    /// Uses the demo's simulated walk for every survey, also with Bluetooth
    /// boards (end-to-end tests run simulated boards over the Bluetooth transport).
    var simulatedWalk = false
    /// A screen to open at launch: "boards", "board" (first demo board), "debugRecords" (Debug builds),
    /// "liveActivity" (the Live Activity layouts, for design review), "nearby" (Nearby Bluetooth).
    var openScreen: String?
    /// Shows the first-launch welcome, which UI-testing launches otherwise skip.
    var showWelcome = false

    init() {}

    init(defaults: UserDefaults) {
        uiTesting = defaults.bool(forKey: "NSUITesting")
        demoBoards = min(max(defaults.integer(forKey: "NSDemoBoards"), 1), 4)
        demoSeed = UInt64(max(defaults.integer(forKey: "NSDemoSeed"), 1))
        autoStartSurvey = defaults.bool(forKey: "NSAutoStartSurvey")
        autoConnectDemo = defaults.bool(forKey: "NSAutoConnectDemo") || autoStartSurvey
        simulatedWalk = defaults.bool(forKey: "NSSimulatedWalk")
        openScreen = defaults.string(forKey: "NSOpenScreen")
        showWelcome = defaults.bool(forKey: "NSShowWelcome")
        if defaults.bool(forKey: "NSOpenDebugRecords") { openScreen = "debugRecords" }
    }
}
