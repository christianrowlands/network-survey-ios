import XCTest

/// The PLMN lookup with made-up operators (UI-testing launches never reach
/// the tower service; see FixtureTowerTransport).
final class PlmnLookupTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSearchFindsOperatorsAndShowsDetail() {
        let app = XCUIApplication()
        app.launchArguments = ["-NSUITesting", "YES"]
        app.launch()
        app.tabBars.buttons["Tools"].tap()
        let row = app.buttons["tools.plmnLookup"]
        if !row.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["PLMN lookup"].waitForExistence(timeout: 5))

        // A name finds every operator with it, by MCC-MNC.
        let field = app.textFields["plmn.input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("example")
        XCTAssertTrue(app.staticTexts["Example Private Network"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["3 operators"].exists)
        attach(app, "plmn-search")

        let example = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'ExampleNet, 001-01'")).firstMatch
        XCTAssertTrue(example.exists)
        example.tap()
        XCTAssertTrue(app.navigationBars["001-01"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["TADIG, XXXEX"].exists)
        XCTAssertTrue(app.staticTexts["Country, Test network"].exists)
        attach(app, "plmn-detail")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // An MCC-MNC matches the MNC as a prefix.
        field.clearAndType("001-01")
        XCTAssertTrue(app.staticTexts["ExampleNet IoT"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Not operational"].exists)
        XCTAssertFalse(app.staticTexts["Sample Mobile"].exists)

        field.clearAndType("zzz")
        XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 5))

        // Without a connection it says so and offers to try again.
        field.clearAndType("offline")
        XCTAssertTrue(app.staticTexts["No connection"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["plmn.retry"].exists)
        attach(app, "plmn-offline")
    }

    @MainActor
    func testTowerDetailLooksUpItsOperator() {
        let app = XCUIApplication()
        app.launchArguments = ["-NSUITesting", "YES"]
        app.launch()
        app.tabBars.buttons["Map"].tap()
        let chip = app.buttons["map.legend.towers"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        chip.tap()
        XCTAssertTrue(app.alerts["Show cell towers?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Show Towers"].tap()

        app.buttons["map.filter"].tap()
        app.buttons["map.towers.search"].tap()
        for (field, value) in [("mcc", "001"), ("mnc", "01"), ("area", "1000"), ("cid", "256")] {
            let input = app.textFields["towers.search.\(field)"]
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.tap()
            input.typeText(value)
        }
        app.buttons["towers.search.go"].tap()

        let lookup = app.buttons["tower.lookupOperator"]
        XCTAssertTrue(app.navigationBars["Tower"].waitForExistence(timeout: 10))
        for _ in 0..<3 where !lookup.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(lookup.waitForExistence(timeout: 5))
        lookup.tap()
        XCTAssertTrue(app.navigationBars["PLMN lookup"].waitForExistence(timeout: 5))
        let operatorRow = app.buttons.containing(NSPredicate(format: "label CONTAINS ', 001-0'")).firstMatch
        XCTAssertTrue(operatorRow.waitForExistence(timeout: 5), "the tower's operator was not looked up")
        XCTAssertEqual((app.textFields["plmn.input"].value as? String)?.hasPrefix("001-0"), true)
        attach(app, "plmn-from-tower")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
