import XCTest

/// Nearby Bluetooth with the simulated scanner that UI-testing launches use.
final class NearbyBluetoothTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Open from Still to do, see devices, open one, hide it, close.
    @MainActor
    func testOpenListDetailHideAndClose() {
        let app = XCUIApplication()
        app.launchArguments = ["-NSUITesting", "YES"]
        app.launch()

        let entry = app.buttons["survey.nearby"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "no Nearby Bluetooth link without a Scout")
        entry.tap()

        XCTAssertTrue(app.navigationBars["Nearby Bluetooth"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["nearby.intro"].exists)
        let rows = app.buttons.matching(identifier: "nearby.device")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "no devices heard")
        XCTAssertEqual(app.buttons["nearby.lookPause"].label, "Pause")
        // Nothing on this screen starts or belongs to a survey.
        XCTAssertFalse(app.buttons["survey.start"].isHittable)

        // The simulated "Demo Speaker" is always the strongest, so it sorts first.
        let speaker = app.staticTexts["Demo Speaker"]
        XCTAssertTrue(speaker.waitForExistence(timeout: 10))
        rows.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Nearby device"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Heard by this iPhone"].exists)
        XCTAssertFalse(app.staticTexts["Address"].exists, "an iPhone-heard device must not show an address")
        let hide = app.buttons["nearby.hide"]
        app.swipeUp()
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        hide.tap()

        XCTAssertTrue(app.navigationBars["Nearby Bluetooth"].waitForExistence(timeout: 5))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        sleep(2)
        XCTAssertFalse(speaker.exists, "the hidden device is still listed")

        app.buttons["nearby.lookPause"].tap()
        XCTAssertEqual(app.buttons["nearby.lookPause"].label, "Look")
        XCTAssertTrue(app.descendants(matching: .any)["nearby.status"].waitForExistence(timeout: 5))

        app.buttons["nearby.done"].tap()
        XCTAssertTrue(app.buttons["survey.start"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Nearby Bluetooth"].exists)
    }

    /// With a Scout connected the link moves below the survey setup, and it
    /// is gone while a survey records.
    @MainActor
    func testLinkFollowsTheScoutAndHidesWhileRecording() {
        let app = XCUIApplication()
        app.launchArguments = ["-NSUITesting", "YES", "-NSAutoConnectDemo", "YES"]
        app.launch()

        let start = app.buttons["survey.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        let chip = app.descendants(matching: .any).matching(identifier: "survey.boardChip").firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        let entry = app.buttons["survey.nearby"]
        app.swipeUp()
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "no Nearby Bluetooth link with a Scout connected")
        XCTAssertEqual(app.buttons.matching(identifier: "survey.nearby").count, 1)

        let deadline = Date().addingTimeInterval(10)
        while !start.isEnabled && Date() < deadline { sleep(1) }
        start.tap()
        XCTAssertTrue(app.staticTexts["survey.heartbeat"].waitForExistence(timeout: 10))
        XCTAssertFalse(entry.exists, "Nearby Bluetooth must not open while a survey records")
    }
}
