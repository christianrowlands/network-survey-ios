import XCTest

final class LaunchTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTabsExist() {
        let app = XCUIApplication()
        app.launchArguments = ["-NSUITesting", "YES"]
        app.launch()
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        for name in ["Survey", "Map", "Lists", "Files", "Settings"] {
            XCTAssertTrue(tabBar.buttons[name].exists, "missing tab \(name)")
        }
        tabBar.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        tabBar.buttons["Survey"].tap()
        XCTAssertTrue(app.navigationBars["Network Survey"].waitForExistence(timeout: 5))
    }

    #if DEBUG
    /// The developer screen exists only in Debug builds.
    @MainActor
    func testDebugListShowsDemoRecords() {
        let app = XCUIApplication()
        app.launchArguments = ["-NSUITesting", "YES", "-NSOpenDebugRecords", "YES"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Live records"].waitForExistence(timeout: 10))
        // The demo board streams records within a second or two of connecting.
        let row = app.descendants(matching: .any).matching(identifier: "debugRecords.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
    }
    #endif
}
