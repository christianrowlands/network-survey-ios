import XCTest

/// The tower layer on the Map with made-up towers (UI-testing launches never
/// reach the tower service). Screenshots go to SCREENSHOT_DIR when it is set.
final class TowerMapTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func save(_ app: XCUIApplication, _ name: String) {
        guard let path = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !path.isEmpty else { return }
        let suffix = ProcessInfo.processInfo.environment["SCREENSHOT_SUFFIX"].map { "-\($0)" } ?? ""
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: directory.appendingPathComponent("towers-\(name)\(suffix).png"))
    }

    @MainActor
    func testTowersFindFilterAndDetail() {
        let app = XCUIApplication()
        app.launchArguments = ["-NSUITesting", "YES"]
        app.launch()
        app.tabBars.buttons["Map"].tap()

        // Turning towers on asks first.
        let chip = app.buttons["map.legend.towers"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        chip.tap()
        XCTAssertTrue(app.alerts["Show cell towers?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Show Towers"].tap()
        XCTAssertTrue(app.buttons["map.towers.filters"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["map.towers.attribution"].exists)

        // Find a tower: the map moves there and shows it.
        app.buttons["map.filter"].tap()
        app.buttons["map.towers.search"].tap()
        for (field, value) in [("mcc", "001"), ("mnc", "01"), ("area", "1000"), ("cid", "256")] {
            let input = app.textFields["towers.search.\(field)"]
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.tap()
            input.typeText(value)
        }
        app.buttons["towers.search.go"].tap()
        XCTAssertTrue(app.collectionViews["tower.detail"].waitForExistence(timeout: 10)
            || app.otherElements["tower.detail"].waitForExistence(timeout: 1))
        save(app, "detail")
        app.swipeDown(velocity: .fast)

        // The area around it fills with towers.
        let marker = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'map.tower'")).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 15), "the map should show towers")
        save(app, "map")

        // Filters apply as they change; with no technology there is nothing to show.
        app.buttons["map.towers.filters"].tap()
        for radio in ["LTE", "NR"] {
            let toggle = app.switches["towers.filter.\(radio)"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            if toggle.value as? String == "1" { toggle.switches.firstMatch.tap() }
        }
        save(app, "filters")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["map.towers.status"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["map.towers.status"].label.contains("No towers"))
    }
}
