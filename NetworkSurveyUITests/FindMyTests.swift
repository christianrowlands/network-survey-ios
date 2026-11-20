import XCTest

/// Find My trackers in the NS Scout Bluetooth list: the demo Scout hears an
/// AirTag and a Find My accessory, both unnamed.
final class FindMyTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testFindMyTagFilterAndDetail() {
        let app = XCUIApplication()
        app.launchArguments = ["-NSUITesting", "YES", "-NSAutoConnectDemo", "YES"]
        app.launch()
        // Bluetooth is off by default.
        let ble = app.buttons["survey.protocol.Bluetooth"]
        XCTAssertTrue(ble.waitForExistence(timeout: 10))
        ble.tap()
        let start = app.buttons["survey.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: start)
        waitForExpectations(timeout: 30)
        start.tap()
        XCTAssertTrue(app.buttons["survey.stop"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Lists"].tap()
        XCTAssertTrue(app.navigationBars["Lists"].waitForExistence(timeout: 5))
        app.buttons["Bluetooth"].tap()

        let airTag = app.cells.containing(NSPredicate(format: "label CONTAINS 'AirTag tracker'")).firstMatch
        XCTAssertTrue(airTag.waitForExistence(timeout: 30), "the demo AirTag has no AirTag tag")
        shot("ble-list")

        setFilter("Find My trackers", in: app)
        let accessory = app.cells.containing(NSPredicate(format: "label CONTAINS 'Find My tracker'")).firstMatch
        XCTAssertTrue(accessory.waitForExistence(timeout: 20), "the demo Find My accessory is missing")
        XCTAssertTrue(airTag.exists)
        XCTAssertTrue(app.staticTexts["2 Bluetooth devices"].waitForExistence(timeout: 10), "only the two trackers should show")
        shot("ble-trackers")

        airTag.tap()
        XCTAssertTrue(app.navigationBars["Bluetooth device"].waitForExistence(timeout: 5))
        shot("ble-airtag-detail-top")
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Find My type, AirTag"].waitForExistence(timeout: 5), "no AirTag Find My type")
        shot("ble-airtag-detail")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Both trackers are unnamed, so Named only leaves nothing.
        setFilter("Named only", in: app)
        XCTAssertTrue(app.staticTexts["Nothing matches the filters."].waitForExistence(timeout: 10))

        // Named only alone keeps named devices and drops the unnamed ones.
        setFilter("Find My trackers", in: app)
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.cells.containing(NSPredicate(format: "label CONTAINS 'Unnamed device'")).firstMatch.exists)
        XCTAssertFalse(airTag.exists)
        shot("ble-named")
    }

    /// Toggles a filter in the Lists filter menu, then closes the menu.
    @MainActor
    private func setFilter(_ title: String, in app: XCUIApplication) {
        app.buttons["lists.filter"].tap()
        let toggle = app.buttons[title]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "no \(title) filter")
        toggle.tap()
        // Tapping outside closes the menu: the empty left end of the title row.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.09)).tap()
        _ = toggle.waitForNonExistence(timeout: 3)
    }

    @MainActor
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
