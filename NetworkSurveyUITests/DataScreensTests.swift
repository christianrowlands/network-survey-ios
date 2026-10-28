import XCTest

/// Smoke flows for the Map, Lists, details, Settings and Files with the demo
/// board. Each launch is isolated (in-memory settings and database).
final class DataScreensTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launchSurveying(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-NSUITesting", "YES", "-NSAutoStartSurvey", "YES"] + extra
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    func testListsSearchDetailAndIgnore() {
        let app = launchSurveying()
        app.tabBars.buttons["Lists"].tap()
        XCTAssertTrue(app.navigationBars["Lists"].waitForExistence(timeout: 5))

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Net")
        let row = app.cells.containing(NSPredicate(format: "label CONTAINS 'Net'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no access point matched the search")
        row.tap()

        XCTAssertTrue(app.navigationBars["Access point"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["BSSID"].waitForExistence(timeout: 5))
        app.buttons["detail.ignore"].tap()
        let ignore = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ignore this access point'")).firstMatch
        XCTAssertTrue(ignore.waitForExistence(timeout: 5))
        ignore.tap()
        XCTAssertTrue(app.alerts["Added to the ignore list"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()

        app.tabBars.buttons["Settings"].tap()
        let ignoreRow = app.buttons["settings.ignoreList"]
        XCTAssertTrue(ignoreRow.waitForExistence(timeout: 5))
        ignoreRow.tap()
        XCTAssertTrue(app.navigationBars["Ignore list"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Access points (BSSID)"].exists)
    }

    /// The survey's counts open the matching list, and probe requests drill
    /// in by network and by client.
    @MainActor
    func testSurveyCountsOpenListsAndProbes() {
        let app = launchSurveying()
        let probes = app.buttons["survey.count.Probe requests"]
        XCTAssertTrue(probes.waitForExistence(timeout: 15))
        probes.tap()
        XCTAssertTrue(app.navigationBars["Lists"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Probes"].isSelected)

        let byNetwork = NSPredicate(format: "label CONTAINS ' client' AND NOT (label BEGINSWITH 'Any network')")
        let network = app.cells.containing(byNetwork).firstMatch
        XCTAssertTrue(network.waitForExistence(timeout: 30), "no probed network appeared")
        network.tap()
        XCTAssertTrue(app.navigationBars["Probed network"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Clients that looked for it"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["By client"].tap()
        let client = app.cells.containing(NSPredicate(format: "label CONTAINS 'Looked for'")).firstMatch
        XCTAssertTrue(client.waitForExistence(timeout: 10), "no probing client appeared")
        client.tap()
        XCTAssertTrue(app.navigationBars["Client"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Networks it looked for"].waitForExistence(timeout: 5))

        // Another count closes the open detail and shows its list.
        app.tabBars.buttons["Survey"].tap()
        let aps = app.buttons["survey.count.Wi-Fi APs"]
        XCTAssertTrue(aps.waitForExistence(timeout: 5))
        aps.tap()
        XCTAssertTrue(app.navigationBars["Lists"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["APs"].isSelected)
        XCTAssertFalse(app.segmentedControls["lists.probeGrouping"].exists)
    }

    @MainActor
    func testMQTTSettingsSave() {
        let app = XCUIApplication()
        app.launchArguments = ["-NSUITesting", "YES"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["settings.mqtt"].tap()
        XCTAssertTrue(app.navigationBars["MQTT"].waitForExistence(timeout: 5))

        app.switches["mqtt.enabled"].switches.firstMatch.tap()
        let host = app.textFields["mqtt.host"]
        host.tap()
        host.typeText("broker.example.com")
        let port = app.textFields["mqtt.port"]
        port.tap()
        port.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        port.typeText(XCUIKeyboardKey.delete.rawValue + "1883")
        app.textFields["mqtt.username"].tap()
        app.textFields["mqtt.username"].typeText("surveyor")

        app.navigationBars["MQTT"].buttons.element(boundBy: 0).tap()
        let row = app.buttons["settings.mqtt"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.staticTexts["broker.example.com"].exists, "Settings row should show the saved host")

        row.tap()
        XCTAssertEqual(app.textFields["mqtt.host"].value as? String, "broker.example.com")
        XCTAssertEqual(app.textFields["mqtt.port"].value as? String, "1883")
        XCTAssertEqual(app.textFields["mqtt.username"].value as? String, "surveyor")
    }

    @MainActor
    func testFilesShowSessionAfterDemoSurvey() {
        let app = launchSurveying()
        app.tabBars.buttons["Files"].tap()
        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 5))
        let wifiCSV = app.staticTexts["Wi-Fi CSV"]
        XCTAssertTrue(wifiCSV.waitForExistence(timeout: 20), "the running survey's Wi-Fi CSV should be listed")
        XCTAssertTrue(app.staticTexts["Recording"].exists)
    }

    /// The zone added on the map is the setting the survey pipeline reads
    /// (Settings > Privacy zones lists `Settings.privacyZones`).
    @MainActor
    func testPrivacyZoneAddedOnMapIsSaved() {
        let app = launchSurveying()
        app.tabBars.buttons["Map"].tap()
        XCTAssertTrue(app.buttons["map.filter"].waitForExistence(timeout: 5))
        app.buttons["map.filter"].tap()
        app.buttons["map.zones"].tap()
        let map = app.otherElements["map.map"].exists ? app.otherElements["map.map"] : app.maps.firstMatch
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.0)
        XCTAssertTrue(app.navigationBars["New privacy zone"].waitForExistence(timeout: 5))
        app.buttons["zone.add"].tap()
        app.buttons["map.zonesDone"].tap()

        app.tabBars.buttons["Settings"].tap()
        let zones = app.buttons["settings.zones"]
        XCTAssertTrue(zones.waitForExistence(timeout: 5))
        XCTAssertTrue(zones.staticTexts["1"].exists, "Settings should count one privacy zone")
        zones.tap()
        XCTAssertTrue(app.staticTexts["Zone 1"].waitForExistence(timeout: 5))
    }

    /// Between surveys Lists show nothing until a past survey is picked, and
    /// a past survey says so.
    @MainActor
    func testListsShowPastSurveyOnlyWhenPicked() {
        let app = launchSurveying()
        let stop = app.buttons["survey.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 15))
        app.tabBars.buttons["Lists"].tap()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 20), "no rows while recording")
        XCTAssertFalse(app.descendants(matching: .any)["pastSurvey.bar"].exists)

        app.tabBars.buttons["Survey"].tap()
        stop.tap()
        app.buttons["survey.confirmStop"].firstMatch.tap()
        XCTAssertTrue(app.buttons["survey.start"].waitForExistence(timeout: 10))

        app.tabBars.buttons["Lists"].tap()
        let showLast = app.buttons["noSurvey.showLast"]
        XCTAssertTrue(showLast.waitForExistence(timeout: 5), "a stopped survey should not stay on Lists")
        XCTAssertTrue(app.staticTexts["Not recording"].exists)
        showLast.tap()
        XCTAssertTrue(app.descendants(matching: .any)["pastSurvey.bar"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 10), "the past survey's rows are missing")

        app.buttons["pastSurvey.close"].tap()
        XCTAssertTrue(showLast.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["pastSurvey.bar"].exists)
    }

    @MainActor
    func testMapShowsMarkers() {
        let app = launchSurveying()
        app.tabBars.buttons["Map"].tap()
        XCTAssertTrue(app.navigationBars["Map"].waitForExistence(timeout: 5))
        let marker = app.buttons.matching(NSPredicate(format: "label CONTAINS 'strongest' OR label BEGINSWITH 'Group of'")).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 30), "map should show markers for the demo survey")
    }
}
