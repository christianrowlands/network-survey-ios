import XCTest

/// Smoke flows for the Survey and Boards screens with the demo board. Each
/// launch is isolated (in-memory settings and database, no Bluetooth).
final class SurveyFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Connect the demo board, start, watch the counts rise, stop and confirm.
    @MainActor
    func testDemoSurveyStartCountStop() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-NSUITesting", "YES"]
        app.launch()

        let start = app.buttons["survey.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertFalse(start.isEnabled, "Start must wait for a board")
        XCTAssertEqual(app.staticTexts["survey.startBlock"].label, "Connect a board to start")

        app.buttons["Find boards"].tap()
        XCTAssertTrue(app.navigationBars["Boards"].waitForExistence(timeout: 5))
        let demo = app.buttons.matching(identifier: "boards.nearby").firstMatch
        XCTAssertTrue(demo.waitForExistence(timeout: 10), "demo board not listed")
        demo.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "boards.yours").firstMatch.waitForExistence(timeout: 10))
        app.navigationBars["Boards"].buttons.firstMatch.tap()

        let chip = app.descendants(matching: .any).matching(identifier: "survey.boardChip").firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        XCTAssertTrue(start.isEnabled)
        start.tap()

        let heartbeat = app.staticTexts["survey.heartbeat"]
        XCTAssertTrue(heartbeat.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["survey.missionId"].label.hasPrefix("Mission ID NS DEMO "))
        let first = try recordCount(heartbeat)
        var count = first
        let deadline = Date().addingTimeInterval(15)
        while count <= first + 20 && Date() < deadline {
            sleep(1)
            count = (try? recordCount(heartbeat)) ?? count
        }
        XCTAssertGreaterThan(count, first + 20, "the record count did not rise")

        let stop = app.buttons["survey.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()
        XCTAssertTrue(app.staticTexts["Stop this survey?"].waitForExistence(timeout: 5))
        app.buttons["survey.confirmStop"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 10), "Start did not come back after Stop")
        XCTAssertTrue(start.isEnabled)
    }

    /// Change a board's role on its Boards detail page and see it in the survey chip.
    @MainActor
    func testBoardRoleChange() {
        let app = XCUIApplication()
        app.launchArguments = ["-NSUITesting", "YES", "-NSAutoConnectDemo", "YES", "-NSOpenScreen", "board"]
        app.launch()

        XCTAssertTrue(app.staticTexts["board.connection"].waitForExistence(timeout: 10))
        let connected = expectation(for: NSPredicate(format: "label == 'Connected'"), evaluatedWith: app.staticTexts["board.connection"])
        wait(for: [connected], timeout: 10)

        let band = app.buttons["role.2.4 GHz only"]
        XCTAssertTrue(band.waitForExistence(timeout: 5))
        XCTAssertFalse(band.isSelected)
        band.tap()
        let selected = expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: band)
        wait(for: [selected], timeout: 5)
        XCTAssertFalse(app.buttons["role.Automatic"].isSelected)

        // The role holds in the running survey: the chip shows the 2.4 GHz channels.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["survey.start"].tap()
        let chip = app.descendants(matching: .any).matching(identifier: "survey.boardChip").firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        let hopping = expectation(for: NSPredicate(format: "label CONTAINS '2.4 GHz · 13 ch'"), evaluatedWith: chip)
        wait(for: [hopping], timeout: 10)
    }

    @MainActor
    private func recordCount(_ heartbeat: XCUIElement) throws -> Int {
        let digits = heartbeat.label.prefix { $0.isNumber || $0 == "," }.filter(\.isNumber)
        return try XCTUnwrap(Int(digits))
    }
}
